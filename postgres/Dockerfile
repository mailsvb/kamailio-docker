FROM postgres:17-alpine
LABEL maintainer="mailsvb <mailsvb@gmail.com>"

# schema and initial settings, executed on first start (empty data volume)
COPY init/ /docker-entrypoint-initdb.d/
