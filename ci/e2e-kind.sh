#!/usr/bin/env bash
# https://github.com/helm/chart-testing/blob/master/examples/kind/test/e2e-kind.sh

set -o errexit
set -o nounset
set -o pipefail

readonly KIND_VERSION=v0.9.0
readonly CLUSTER_NAME=chart-testing
readonly K8S_VERSION=v1.18.0

output(){
    echo ""
    echo "*******************************************************"
    echo "$1"
    echo "*******************************************************"
    echo ""
}

run_ct_container() {
    echo 'Running ct container...'
    docker run --rm --interactive --detach --network host --name ct \
        --volume "$(pwd)/ci/ct.yaml:/etc/ct/ct.yaml" \
        --volume "$(pwd):/workdir" \
        --workdir /workdir \
        "gcr.io/kubernetes-charts-ci/test-image:v3.4.1" \
        cat
    echo
}

cleanup() {
    echo 'Removing ct container...'
    docker kill ct > /dev/null 2>&1
    docker kill kind-registry > /dev/null 2>&1
    kind delete cluster --name "$CLUSTER_NAME" || /bin/true
    echo 'Done!'
}

docker_exec() {
    docker exec -i ct "$@"
}

create_kind_cluster() {

    if [ "$(command -v kind)" == "" ]; then
        if [ "$(uname -s)" == "Linux" ]; then
            echo 'Installing kind...'
            curl -sSLo kind "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-amd64"
            chmod +x kind
            sudo mv kind /usr/local/bin/kind
        else
            echo "Please install kind for your OS!"
            exit 1
        fi
    fi

    # create registry container unless it already exists
    reg_name='kind-registry'
    reg_port='5000'
    running="$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)"
    if [ "${running}" != 'true' ]; then
      docker run \
        -d --restart=always -p "${reg_port}:5000" --name "${reg_name}" \
        registry:2
    fi
    reg_ip="$(docker inspect -f '{{.NetworkSettings.IPAddress}}' "${reg_name}")"

# create a cluster with the local registry enabled in containerd
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --image "kindest/node:$K8S_VERSION" --wait 60s --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${reg_port}"]
    endpoint = ["http://${reg_ip}:${reg_port}"]
nodes:
  - role: control-plane
  - role: worker
EOF

    docker cp ~/.kube/config ct:/root/.kube/config
    echo

    docker_exec kubectl cluster-info
    echo

    docker_exec kubectl get nodes
    echo

    echo 'Cluster ready!'
    echo
}

install_charts() {
    docker_exec ct install
    echo 'Charts applied'
}

main() {
    # Determine if frontend/backend or both should be tested
    set_testable_components
    run_ct_container
    trap cleanup EXIT
    create_kind_cluster
    install_charts
}

main
