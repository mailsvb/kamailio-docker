// admin: web UI to edit the kamailio configuration tables and to
// reload / restart kamailio. No authentication, meant for lab use.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed web
var webFS embed.FS

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

type server struct {
	db  *DB
	kam *Kamailio
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"error": err.Error()})
}

func (s *server) lookupTable(w http.ResponseWriter, r *http.Request, name string) *Table {
	t, err := s.db.table(r.Context(), name)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return nil
	}
	if t == nil {
		writeErr(w, http.StatusNotFound, errors.New("unknown table "+name))
		return nil
	}
	return t
}

func (s *server) listTables(w http.ResponseWriter, r *http.Request) {
	names, err := s.db.tableNames(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, names)
}

func (s *server) getTable(w http.ResponseWriter, r *http.Request) {
	t := s.lookupTable(w, r, r.PathValue("table"))
	if t == nil {
		return
	}
	rows, err := s.db.rows(r.Context(), t)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"table": t, "rows": rows})
}

func (s *server) saveTable(w http.ResponseWriter, r *http.Request) {
	t := s.lookupTable(w, r, r.PathValue("table"))
	if t == nil {
		return
	}
	var ch Changes
	if err := json.NewDecoder(r.Body).Decode(&ch); err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	if err := s.db.save(r.Context(), t, &ch); err != nil {
		writeErr(w, http.StatusUnprocessableEntity, err)
		return
	}
	log.Printf("table %s saved: %d inserts, %d updates, %d deletes", t.Name, len(ch.Inserts), len(ch.Updates), len(ch.Deletes))
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *server) getOptions(w http.ResponseWriter, r *http.Request) {
	t := s.lookupTable(w, r, r.PathValue("table"))
	if t == nil {
		return
	}
	opts, err := s.db.options(r.Context(), t, r.PathValue("column"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	writeJSON(w, http.StatusOK, opts)
}

func (s *server) rpc(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Method string `json:"method"`
		Params []any  `json:"params"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Method == "" {
		writeErr(w, http.StatusBadRequest, errors.New("method required"))
		return
	}
	res, err := s.kam.rpc(body.Method, body.Params)
	if err != nil {
		writeErr(w, http.StatusBadGateway, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"result": res})
}

func (s *server) reload(w http.ResponseWriter, r *http.Request) {
	if _, err := s.kam.rpc("uac.reg_reload", nil); err != nil {
		writeErr(w, http.StatusBadGateway, err)
		return
	}
	log.Print("uac registrations reloaded")
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *server) restart(w http.ResponseWriter, r *http.Request) {
	how, err := s.kam.restart(r.Context())
	if err != nil {
		writeErr(w, http.StatusBadGateway, err)
		return
	}
	log.Printf("kamailio restarted (%s)", how)
	writeJSON(w, http.StatusOK, map[string]string{"method": how})
}

// status collects container state and RPC information, errors are reported per source
func (s *server) status(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{}
	if s.kam.hasDocker() {
		if st, err := s.kam.containerState(r.Context()); err != nil {
			out["containerError"] = err.Error()
		} else {
			out["container"] = st
		}
	}
	if v, err := s.kam.rpc("core.uptime", nil); err != nil {
		out["rpcError"] = err.Error()
	} else {
		out["uptime"] = v
		if v, err := s.kam.rpc("core.version", nil); err == nil {
			out["version"] = v
		}
		if v, err := s.kam.rpc("uac.reg_dump", nil); err == nil {
			out["registrations"] = v
		}
	}
	writeJSON(w, http.StatusOK, out)
}

func main() {
	listen := env("ADMIN_LISTEN", "0.0.0.0:8080")
	dbURL := os.Getenv("DBURL")
	if dbURL == "" {
		log.Fatal("DBURL not set")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	pool, err := pgxpool.New(ctx, dbURL)
	cancel()
	if err != nil {
		log.Fatal(err)
	}
	defer pool.Close()

	s := &server{
		db: &DB{pool: pool},
		kam: newKamailio(
			env("KAMAILIO_RPC_SOCKET", "/var/run/kamailio/kamailio_rpc.sock"),
			env("DOCKER_SOCKET", "/var/run/docker.sock"),
			env("KAMAILIO_CONTAINER", "kamailio")),
	}

	web, _ := fs.Sub(webFS, "web")
	mux := http.NewServeMux()
	mux.Handle("GET /", http.FileServerFS(web))
	mux.HandleFunc("GET /api/tables", s.listTables)
	mux.HandleFunc("GET /api/tables/{table}", s.getTable)
	mux.HandleFunc("POST /api/tables/{table}/save", s.saveTable)
	mux.HandleFunc("GET /api/options/{table}/{column}", s.getOptions)
	mux.HandleFunc("GET /api/kamailio/status", s.status)
	mux.HandleFunc("POST /api/kamailio/rpc", s.rpc)
	mux.HandleFunc("POST /api/kamailio/reload", s.reload)
	mux.HandleFunc("POST /api/kamailio/restart", s.restart)

	log.Printf("admin listening on %s", listen)
	log.Fatal(http.ListenAndServe(listen, mux))
}
