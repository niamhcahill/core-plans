init_pgpass() {
  cat > {{pkg.svc_var_path}}/.pgpass<<EOF
*:*:*:{{cfg.superuser.name}}:{{cfg.superuser.password}}
*:*:*:{{cfg.replication.name}}:{{cfg.replication.password}}
EOF
chmod 0600 {{pkg.svc_var_path}}/.pgpass
  export PGPASSFILE="{{pkg.svc_var_path}}/.pgpass"
}

write_local_conf() {
  echo 'Writing postgresql.local.conf file based on memory settings'
  cat > {{pkg.svc_config_path}}/postgresql.local.conf<<LOCAL
# Auto-generated memory defaults created at service start by Habitat
effective_cache_size=$(awk '/MemTotal/ {printf( "%.0f\n", ($2 / 1024 / 4) *3 )}' /proc/meminfo)MB
shared_buffers=$(awk '/MemTotal/ {printf( "%.0f\n", $2 / 1024 / 4 )}' /proc/meminfo)MB
maintenance_work_mem=$(awk '/MemTotal/ {printf( "%.0f\n", $2 / 1024 / 16 )}' /proc/meminfo)MB
work_mem=$(awk '/MemTotal/ {printf( "%.0f\n", (($2 / 1024 / 4) *3) / ({{cfg.max_connections}} *3) )}' /proc/meminfo)MB
temp_buffers=$(awk '/MemTotal/ {printf( "%.0f\n", (($2 / 1024 / 4) *3) / ({{cfg.max_connections}}*3) )}' /proc/meminfo)MB
LOCAL
}

write_env_var() {
  echo "$1" > "{{pkg.svc_config_path}}/env/$2"
}

setup_replication_user_in_master() {
  echo 'Making sure replication role exists on Master'
  psql -U {{cfg.superuser.name}}  -h {{svc.leader.sys.ip}} -p {{cfg.port}} postgres >/dev/null 2>&1 << EOF
DO \$$
  BEGIN
  SET synchronous_commit = off;
  PERFORM * FROM pg_authid WHERE rolname = '{{cfg.replication.name}}';
  IF FOUND THEN
    ALTER ROLE "{{cfg.replication.name}}" WITH REPLICATION LOGIN PASSWORD '{{cfg.replication.password}}';
  ELSE
    CREATE ROLE "{{cfg.replication.name}}" WITH REPLICATION LOGIN PASSWORD '{{cfg.replication.password}}';
  END IF;
END;
\$$
EOF
}

# TODO: change this to use pg_controldata
#      then, write a function to extract the be latest checkpoint location using pg_controldata,
#      this allows us to grab the location even when pgsql is down
#      then, turn that into an integer ( equivalent of SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::bigint; )
# like /hab/pkgs/jeremymv2/postgresql/11.1/20181205163000/bin/pg_controldata --pgdata /hab/svc/postgresql/data/pgdata
#
# [root@ip-10-1-1-61 config]# /hab/pkgs/jeremymv2/postgresql/11.1/20181205163000/bin/pg_controldata --pgdata /hab/svc/postgresql/data/pgdata
# pg_control version number:            1100
# Catalog version number:               201809051
# Database system identifier:           6636384425033457352
# Database cluster state:               in archive recovery
# pg_control last modified:             Tue 18 Dec 2018 09:59:13 PM UTC
# Latest checkpoint location:           0/3000098
# Latest checkpoint's REDO location:    0/3000060
# Latest checkpoint's REDO WAL file:    000000010000000000000003

local_xlog_position() {
  psql -U {{cfg.superuser.name}} -h localhost -p {{cfg.port}} postgres -t <<EOF | tr -d '[:space:]'
SELECT CASE WHEN pg_is_in_recovery()
  THEN GREATEST(pg_wal_lsn_diff(COALESCE(pg_last_wal_receive_lsn(), '0/0'), '0/0')::bigint,
                pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '0/0')::bigint)
  ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::bigint
END;
EOF
}

master_xlog_position() {
  psql -U {{cfg.superuser.name}} -h {{svc.leader.sys.ip}} -p {{cfg.port}} postgres -t <<EOF | tr -d '[:space:]'
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::bigint;
EOF
}

master_ready() {
  pg_isready -U {{cfg.superuser.name}} -h {{svc.leader.sys.ip}} -p {{cfg.port}}
}

bootstrap_replica_via_pg_basebackup() {
  echo 'Bootstrapping replica via pg_basebackup from leader '
  rm -rf {{pkg.svc_data_path}}/pgdata/*
  pg_basebackup --verbose --progress --pgdata={{pkg.svc_data_path}}/pgdata --dbname='postgres://{{cfg.replication.name}}@{{svc.leader.sys.ip}}:{{cfg.port}}/postgres'
}

ensure_dir_ownership() {
  paths="{{pkg.svc_var_path}} {{pkg.svc_data_path}}/pgdata {{pkg.svc_data_path}}/archive"
  if [[ $EUID -eq 0 ]]; then
    # if EUID is root, so we should chown to pkg_svc_user:pkg_svc_group
    ownership_command="chown -RL {{pkg.svc_user}}:{{pkg.svc_group}} $paths"
  else
    # not root, so at best we can only chgrp to the effective user's primary group
    ownership_command="chgrp -RL $(id -g) $paths"
  fi
  echo "Ensuring proper ownership: $ownership_command"
  $ownership_command
  chmod 0700 {{pkg.svc_data_path}}/pgdata
}

promote_to_leader() {
  if [ -f {{pkg.svc_data_path}}/pgdata/recovery.conf ]; then
    echo "Promoting database"
    until pg_isready -U {{cfg.superuser.name}} -h localhost -p {{cfg.port}}; do
      echo "Waiting for database to start"
      sleep 1
    done

    pg_ctl promote -D {{pkg.svc_data_path}}/pgdata
  fi
}
