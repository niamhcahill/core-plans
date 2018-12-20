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

setup_replication_user_in_primary() {
  echo 'Making sure replication role exists on Primary'
  psql -U {{cfg.superuser.name}}  -h {{svc.leader.sys.ip}} -p {{svc.leader.cfg.port}} postgres >/dev/null 2>&1 << EOF
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

local_xlog_position_online() {
  psql -U {{cfg.superuser.name}} -h localhost -p {{cfg.port}} postgres -t <<EOF | tr -d '[:space:]'
SELECT CASE WHEN pg_is_in_recovery()
  THEN GREATEST(pg_wal_lsn_diff(COALESCE(pg_last_wal_receive_lsn(), '0/0'), '0/0')::bigint,
                pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '0/0')::bigint)
  ELSE pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::bigint
END;
EOF
}

get_pgcontroldata_value() {
  pg_controldata --pgdata /hab/svc/postgresql/data/pgdata | \
    grep "${1}" | \
    awk -F: '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}'
}

# Use pg_controldata to putput our current xlog position, in the case that
# PG is offline - for example if starting up after a full cluster shutdown
# and needing to elect a leader
# Special thanks to Patroni for figuring this out: https://github.com/zalando/patroni/blob/master/patroni/postgresql.py#L1272-L1286
local_xlog_position_offline() {
  lsn_hex=$(get_pgcontroldata_value 'Minimum recovery ending location')
  timeline=$(get_pgcontroldata_value "Min recovery ending loc's timeline")

  if [[ $lsn_hex == '0/0' || $timeline == '0' ]]
  then
    # it was a leader when it crashed, use a different attribute
    lsn_hex=$(get_pgcontroldata_value 'Latest checkpoint location')
    timeline=$(get_pgcontroldata_value "Latest checkpoint's TimeLineID")
  fi

  # This perl one-liner returns 0 if lsn_hex is empty, in case either pg_controldata or grep failed
  # otherwise it converts the hex log position to a decimal
  # Borrowed from patroni and converted to Perl, since we already dep on a Perl interpeter
  perl -le 'my $lsn = $ARGV[0]; my @t = split /\//, $lsn; my $lsn_dec = hex(@t[0]) * hex(0x100000000) + hex(@t[1]); print $lsn_dec' -- "${lsn_hex}"
}

local_xlog_position() {
  if pg_isready -U {{cfg.superuser.name}} -h {{sys.ip}} -p {{cfg.port}} >/dev/null 2>&1
  then
    local_xlog_position_online
  else
    local_xlog_position_offline
  fi
}

primary_xlog_position() {
  psql -U {{cfg.superuser.name}} -h {{svc.leader.sys.ip}} -p {{svc.leader.cfg.port}} postgres -t <<EOF | tr -d '[:space:]'
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::bigint;
EOF
}

primary_ready() {
  pg_isready -U {{cfg.superuser.name}} -h {{svc.leader.sys.ip}} -p {{svc.leader.cfg.port}}
}

bootstrap_replica_via_pg_basebackup() {
  echo 'Bootstrapping replica via pg_basebackup from leader '
  rm -rf {{pkg.svc_data_path}}/pgdata/*
  pg_basebackup --verbose --progress --pgdata={{pkg.svc_data_path}}/pgdata --dbname='postgres://{{cfg.replication.name}}@{{svc.leader.sys.ip}}:{{svc.leader.cfg.port}}/postgres'
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
