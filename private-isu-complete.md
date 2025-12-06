# Enabling MySQL Slow Query Log

```bash
mkdir -p etc/mysql/conf.d
cat <<'EOF' > etc/mysql/conf.d/my.cnf
[mysqld]
slow_query_log = ON
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 0.1
log_queries_not_using_indexes = ON
EOF
docker compose up -d mysql --force-recreate
```

```bash
docker compose exec mysql cat /var/log/mysql/slow.log > slow.log
```

```bash
brew install percona-toolkit
pt-query-digest slow.log
```

```bash
docker compose exec mysql rm /var/log/mysql/slow.log
```

# Docker Compose Utility Commands

### Logs

```bash
docker compose logs -f app
docker compose logs -f nginx
docker compose exec db cat /var/log/mysql/slow.log
```

### DB Operations

```bash
docker compose exec mysql mysql -u root -p root
```

# Benchmark Execution (Docker Compose)

```bash
docker compose run --rm bench ./bin/benchmarker -u ./userdata -t http://app:8080/
```

# Nginx log


```sh
brew install alp
```

```sh
cat <<'EOF' > etc/nginx/conf.d/nginx.conf
log_format json escape=json '{'
        '"time": "$time_iso8601",'
        '"host": "$remote_addr",'
        '"port": "$remote_port",'
        '"method": "$request_method",'
        '"uri": "$request_uri",'
        '"status": "$status",'
        '"body_bytes": "$body_bytes_sent",'
        '"referer": "$http_referer",'
        '"ua": "$http_user_agent",'
        '"request_time": "$request_time",'
        '"response_time": "$upstream_response_time"'
'}';

access_log /var/log/nginx/access.log json;
EOF
```

# Rotation

docker compose exec nginx rm /var/log/nginx/access.log
docker compose exec nginx cat /var/log/nginx/access.log | alp json -m "/posts/.+,/image/.+,/js/.+,/css/.+,/@.*" > alp.log


docker compose exec mysql rm /var/log/mysql/slow.log
docker compose exec mysql cat /var/log/mysql/slow.log > slow.log
pt-query-digest slow.log
