### comments.post_id に index

docker compose exec -T mysql mysql -uroot -proot -D isuconp \
  -e "ALTER TABLE comments ADD INDEX post_id_idx (post_id, created_at DESC);"

### unicorn worker

```sh
cat <<'EOF' > ruby/unicorn_config.rb
worker_processes 4
preload_app true
listen "0.0.0.0:8080"
EOF
```

### 静的ファイルを nginx 配信

```sh
cat <<'EOF' > etc/nginx/conf.d/default.conf
server {
  listen 80;

  client_max_body_size 10m;
  root /public/;

  location ~ ^/(favicon\.ico|css/|js/|img/) {
    expires 1d;
  }

  location / {
    proxy_set_header Host $host;
    proxy_pass http://app:8080;
  }
}
EOF
```

---

### 画像の静的化

アップロード時に public/image 以下へ保存し、try_files を利用。

```sh
mkddir -p public/image
```

```sh
cat <<'EOF' > etc/nginx/conf.d/default.conf
server {
  listen 80;

  client_max_body_size 10m;
  root /public/;

  location ~ ^/(favicon\.ico|css/|js/|img/) {
    expires 1d;
  }

  location /image/ {
    expires 1d;
    try_files $uri @app;
  }

  location / {
    proxy_set_header Host $host;
    proxy_pass http://app:8080;
  }

  location @app {
    internal;
    proxy_set_header Host $host;
    proxy_pass http://app:8080;
  }
}
EOF
```

### GET / の高速化 （JOIN + LIMIT）

```sql
SELECT p.id, p.user_id, p.body, p.created_at, p.mime, u.account_name
FROM posts p JOIN users u ON p.user_id=u.id
WHERE u.del_flg=0
ORDER BY p.created_at DESC
LIMIT 20;
```

```sh
docker compose exec -T mysql mysql -uroot -proot -D isuconp \
  -e "ALTER TABLE posts ADD INDEX posts_order_idx (created_at DESC);"
```


### comments index

```sh
docker compose exec -T mysql mysql -uroot -proot -D isuconp \
  -e "ALTER TABLE comments ADD INDEX idx_user_id (user_id);"
```

### posts の N+1 memcached

```sh
docker compose exec -T mysql mysql -uroot -proot -D isuconp \
  -e "ALTER TABLE posts ADD INDEX posts_user_idx (user_id,created_at DESC);"
```

```sh
cat <<'EOF' > etc/mysql/conf.d/my.cnf
[mysqld]
slow_query_log = ON
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 0.1
log_queries_not_using_indexes = ON

innodb_flush_log_at_trx_commit = 2
disable-log-bin = 1
EOF
```

## memcached の N+1 を解消 （get_multi）

```ruby
count_keys = results.map { |post| "comments.#{post[:id]}.count" }
cached_counts = memcached.get_multi(count_keys)
```

---


```sh
docker compose exec -T mysql mysql -uroot -proot -D isuconp \
  -e "ALTER TABLE users ADD INDEX idx_del_flg_id (del_flg, id);"
```


```sh
docker compose exec -T mysql mysql -uroot -proot -D isuconp \
  -e "ALTER TABLE posts ADD COLUMN comment_count INT NOT NULL DEFAULT 0;"
```