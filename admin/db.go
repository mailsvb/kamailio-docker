package main

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// tables that are shown but cannot be edited
var readOnlyTables = map[string]bool{"version": true}

type Column struct {
	Name     string  `json:"name"`
	Type     string  `json:"type"`
	Nullable bool    `json:"nullable"`
	Default  *string `json:"default"`
	PK       bool    `json:"pk"`
	FKTable  string  `json:"fkTable,omitempty"`
	FKColumn string  `json:"fkColumn,omitempty"`
}

type Table struct {
	Name     string   `json:"name"`
	ReadOnly bool     `json:"readOnly"`
	Columns  []Column `json:"columns"`
}

type DB struct {
	pool *pgxpool.Pool
}

func (d *DB) tableNames(ctx context.Context) ([]string, error) {
	rows, err := d.pool.Query(ctx, `
		SELECT table_name FROM information_schema.tables
		WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
		ORDER BY table_name`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// table returns the schema of a table of schema public, nil if it does not exist
func (d *DB) table(ctx context.Context, name string) (*Table, error) {
	rows, err := d.pool.Query(ctx, `
		SELECT a.attname,
		       format_type(a.atttypid, a.atttypmod),
		       NOT a.attnotnull,
		       pg_get_expr(ad.adbin, ad.adrelid),
		       coalesce(a.attnum = ANY(pk.conkey), false),
		       coalesce(fr.relname, ''),
		       coalesce(fa.attname, '')
		FROM pg_attribute a
		JOIN pg_class c ON c.oid = a.attrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
		LEFT JOIN pg_constraint pk ON pk.conrelid = c.oid AND pk.contype = 'p'
		LEFT JOIN pg_constraint fk ON fk.conrelid = c.oid AND fk.contype = 'f'
		     AND array_length(fk.conkey, 1) = 1 AND fk.conkey[1] = a.attnum
		LEFT JOIN pg_class fr ON fr.oid = fk.confrelid
		LEFT JOIN pg_attribute fa ON fa.attrelid = fk.confrelid AND fa.attnum = fk.confkey[1]
		WHERE n.nspname = 'public' AND c.relname = $1 AND c.relkind = 'r'
		  AND a.attnum > 0 AND NOT a.attisdropped
		ORDER BY a.attnum`, name)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	t := &Table{Name: name, ReadOnly: readOnlyTables[name]}
	for rows.Next() {
		var c Column
		if err := rows.Scan(&c.Name, &c.Type, &c.Nullable, &c.Default, &c.PK, &c.FKTable, &c.FKColumn); err != nil {
			return nil, err
		}
		t.Columns = append(t.Columns, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(t.Columns) == 0 {
		return nil, nil
	}
	return t, nil
}

func (t *Table) column(name string) *Column {
	for i := range t.Columns {
		if t.Columns[i].Name == name {
			return &t.Columns[i]
		}
	}
	return nil
}

func (t *Table) pkColumns() []Column {
	var pk []Column
	for _, c := range t.Columns {
		if c.PK {
			pk = append(pk, c)
		}
	}
	return pk
}

func ident(s string) string { return pgx.Identifier{s}.Sanitize() }

// rows returns all rows, every value as text (or nil for NULL)
func (d *DB) rows(ctx context.Context, t *Table) ([][]*string, error) {
	cols := make([]string, len(t.Columns))
	for i, c := range t.Columns {
		cols[i] = ident(c.Name) + "::text"
	}
	order := "1"
	if pk := t.pkColumns(); len(pk) > 0 {
		names := make([]string, len(pk))
		for i, c := range pk {
			names[i] = ident(c.Name)
		}
		order = strings.Join(names, ", ")
	}
	rows, err := d.pool.Query(ctx, fmt.Sprintf("SELECT %s FROM %s ORDER BY %s",
		strings.Join(cols, ", "), ident(t.Name), order))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := [][]*string{}
	for rows.Next() {
		vals := make([]*string, len(t.Columns))
		ptrs := make([]any, len(vals))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		result = append(result, vals)
	}
	return result, rows.Err()
}

// Values maps column names to text values, nil means NULL
type Values map[string]*string

type Changes struct {
	Inserts []Values `json:"inserts"`
	Updates []struct {
		PK  Values `json:"pk"`
		Set Values `json:"set"`
	} `json:"updates"`
	Deletes []struct {
		PK Values `json:"pk"`
	} `json:"deletes"`
}

// builder collects SQL parameters, every value is cast from text to the column type
type builder struct {
	t    *Table
	args []any
}

func (b *builder) value(col string, v *string) (string, error) {
	c := b.t.column(col)
	if c == nil {
		return "", fmt.Errorf("unknown column %q", col)
	}
	b.args = append(b.args, v)
	return fmt.Sprintf("$%d::text::%s", len(b.args), c.Type), nil
}

func (b *builder) where(pk Values) (string, error) {
	pkCols := b.t.pkColumns()
	if len(pkCols) == 0 {
		return "", errors.New("table has no primary key")
	}
	conds := make([]string, len(pkCols))
	for i, c := range pkCols {
		v, ok := pk[c.Name]
		if !ok || v == nil {
			return "", fmt.Errorf("missing primary key column %q", c.Name)
		}
		p, err := b.value(c.Name, v)
		if err != nil {
			return "", err
		}
		conds[i] = ident(c.Name) + " = " + p
	}
	return strings.Join(conds, " AND "), nil
}

// save applies all changes in one transaction: deletes, updates, then inserts
func (d *DB) save(ctx context.Context, t *Table, ch *Changes) error {
	if t.ReadOnly {
		return fmt.Errorf("table %s is read-only", t.Name)
	}
	tx, err := d.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	exec := func(what string, n int, sql string, args []any) error {
		tag, err := tx.Exec(ctx, sql, args...)
		if err != nil {
			return fmt.Errorf("%s row %d: %w", what, n+1, err)
		}
		if tag.RowsAffected() != 1 {
			return fmt.Errorf("%s row %d: %d rows affected (changed concurrently?)", what, n+1, tag.RowsAffected())
		}
		return nil
	}

	for i, del := range ch.Deletes {
		b := &builder{t: t}
		w, err := b.where(del.PK)
		if err != nil {
			return fmt.Errorf("delete row %d: %w", i+1, err)
		}
		if err := exec("delete", i, fmt.Sprintf("DELETE FROM %s WHERE %s", ident(t.Name), w), b.args); err != nil {
			return err
		}
	}
	for i, up := range ch.Updates {
		if len(up.Set) == 0 {
			continue
		}
		b := &builder{t: t}
		var sets []string
		for col, v := range up.Set {
			p, err := b.value(col, v)
			if err != nil {
				return fmt.Errorf("update row %d: %w", i+1, err)
			}
			sets = append(sets, ident(col)+" = "+p)
		}
		w, err := b.where(up.PK)
		if err != nil {
			return fmt.Errorf("update row %d: %w", i+1, err)
		}
		sql := fmt.Sprintf("UPDATE %s SET %s WHERE %s", ident(t.Name), strings.Join(sets, ", "), w)
		if err := exec("update", i, sql, b.args); err != nil {
			return err
		}
	}
	for i, ins := range ch.Inserts {
		b := &builder{t: t}
		var cols, vals []string
		for col, v := range ins {
			p, err := b.value(col, v)
			if err != nil {
				return fmt.Errorf("insert row %d: %w", i+1, err)
			}
			cols = append(cols, ident(col))
			vals = append(vals, p)
		}
		sql := fmt.Sprintf("INSERT INTO %s DEFAULT VALUES", ident(t.Name))
		if len(cols) > 0 {
			sql = fmt.Sprintf("INSERT INTO %s (%s) VALUES (%s)", ident(t.Name), strings.Join(cols, ", "), strings.Join(vals, ", "))
		}
		if err := exec("insert", i, sql, b.args); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

type Option struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

// options returns the rows of a referenced table as value/label pairs for dropdowns
func (d *DB) options(ctx context.Context, t *Table, col string) ([]Option, error) {
	if t.column(col) == nil {
		return nil, fmt.Errorf("unknown column %q", col)
	}
	label := ident(col) + "::text"
	for _, c := range t.Columns {
		if c.Name != col && (strings.HasPrefix(c.Type, "character varying") || c.Type == "text") {
			label = ident(col) + "::text || ' – ' || " + ident(c.Name)
			break
		}
	}
	rows, err := d.pool.Query(ctx, fmt.Sprintf("SELECT %s::text, %s FROM %s ORDER BY %s",
		ident(col), label, ident(t.Name), ident(col)))
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Option, error) {
		var o Option
		err := r.Scan(&o.Value, &o.Label)
		return o, err
	})
}
