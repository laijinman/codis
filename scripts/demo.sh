#!/bin/bash

PATH=$PATH:`realpath ../bin`

for x in etcd codis-dashboard codis-proxy codis-admin codis-server; do
    which $x >/dev/null
    if [ $? -ne 0 ]; then
        echo "missing $x"
        exit 1
    fi
done

rm -rf tmp; mkdir -p tmp && pushd tmp
if [ $? -ne 0 ]; then
    echo "pushd failed"
    exit 1
fi

trap "kill 0" EXIT SIGQUIT SIGKILL SIGTERM

nohup etcd --name=codis-test &>etcd.log &
lastpid=$!
pidlist=$lastpid
echo "etcd.pid=$lastpid"

for ((i=0;i<8;i++)); do
    let p="16379+i"
    nohup codis-server --port ${p} &>redis-${p}.log &
    lastpid=$!
    pidlist="$pidlist $lastpid"
    echo "codis-server-${p}.pid=$lastpid"
done

for ((i=0;i<5;i++)); do
    let p="26379+i"
    > sentinel-${p}.conf
    nohup codis-server sentinel-${p}.conf --port ${p} --sentinel &>sentinel-${p}.log &
    lastpid=$!
    pidlist="$pidlist $lastpid"
    echo "sentinel-${p}.pid=$lastpid"
done

for ((i=0;i<4;i++)); do
    let p1="11080+i"
    let p2="19000+i"
    cat > ${p1}.toml <<EOF
product_name = "codis-test"
product_auth = ""
proto_type = "tcp4"
admin_addr = "0.0.0.0:${p1}"
proxy_addr = "0.0.0.0:${p2}"
proxy_datacenter = "localhost"
proxy_heap_placeholder = "0"
proxy_max_offheap_size = "0"
EOF
    nohup codis-proxy -c ${p1}.toml &>${p1}.log &
    lastpid=$!
    pidlist="$pidlist $lastpid"
    echo "proxy-${p1}x${p2}.pid=$lastpid"
done

cat > dashboard.toml <<EOF
coordinator_name = "etcd"
coordinator_addr = "127.0.0.1:2379"
product_name = "codis-test"
product_auth = ""
admin_addr = "0.0.0.0:18080"
EOF

nohup codis-dashboard -c dashboard.toml &> dashboard.log &
lastpid=$!
pidlist="$pidlist $lastpid"
echo "dashboard.pid=$lastpid"

nohup codis-fe --etcd 127.0.0.1:2379 --listen 0.0.0.0:8080 --assets-dir ../../cmd/fe/assets &> fe.log &
lastpid=$!
pidlist="$pidlist $lastpid"
echo "fe.pid=$lastpid"

sleep 3

for pid in $pidlist; do
    ps -p $pid >/dev/null
    if [ $? -ne 0 ]; then
        echo "pid=$pid not found"
        exit 1
    fi
done

codis_admin() {
    codis-admin --dashboard=127.0.0.1:18080 $@
    if [ $? -ne 0 ]; then
        echo "codis-admin error: $@"
        exit 1
    fi
}

for ((i=0;i<4;i++)); do
    let g="i+1"
    codis_admin --create-group --gid $g
done

for ((i=0;i<8;i++)); do
    let p="16379+i"
    let g="i/2+1"
    codis_admin --group-add --gid $g -x 127.0.0.1:${p} --datacenter "localhost"
done

for ((i=0;i<4;i++)); do
    let p1="11080+i"
    codis_admin --create-proxy -x 127.0.0.1:${p1}
done

for ((i=0;i<5;i++)); do
    let p1="26379+i"
    codis_admin --sentinel-add -x 127.0.0.1:${p1}
done

codis_admin --slot-action --interval=100
codis_admin --rebalance --confirm
codis_admin --sentinel-resync

echo done

while true; do
    date
    sleep 60
done
