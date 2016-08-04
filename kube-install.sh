#!/bin/bash -e

print_help() {
  echo "Usage: 
  ./kube-installer.sh

  Options:
    --master <master ip address>                       Install kube master with provided IP
    --slave  <slave ip address> <master ip address>    Install kube slave with provided IP 
  "
}

if [[ $# > 0 ]]; then
  if [[ "$1" == "--slave" ]]; then
    export INSTALLER_TYPE=slave
    if [[ ! -z "$2" ]] && [[ ! -z "$3" ]]; then
      export SLAVE_IP=$2
      export MASTER_IP=$3
    else
      echo "Error!! missing Slave IP or Master IP"
      print_help
      exit 1
    fi
  elif [[ "$1" == "--master" ]]; then
    export INSTALLER_TYPE=master
    if [[ ! -z "$2" ]]; then
      export MASTER_IP=$2
    else
      echo "Error!! please provide Master IP"
      print_help
      exit 1
    fi
  else
    print_help
    exit 1
  fi
else
  print_help
  exit 1
fi

echo "####################################################################"
echo "#################### Installing kubernetes $INSTALLER_TYPE #########"
echo "####################################################################"

export KUBERNETES_RELEASE_VERSION=v1.2.4
export ETCD_VERSION=v2.3.1
export DEFAULT_CONFIG_PATH=/etc/default
export ETCD_EXECUTABLE_LOCATION=/usr/bin
export FLANNEL_EXECUTABLE_LOCATION=/usr/bin
export ETCD_PORT=2379
export FLANNEL_SUBNET=10.100.0.0/16
export FLANNEL_VERSION=0.5.5
export DOCKER_VERSION=1.6.2
export KUBERNETES_CLUSTER_ID=k8sCluster
export KUBERNETES_DOWNLOAD_PATH=/tmp
export KUBERNETES_EXTRACT_DIR=$KUBERNETES_DOWNLOAD_PATH/kubernetes
export KUBERNETES_DIR=$KUBERNETES_EXTRACT_DIR/kubernetes
export KUBERNETES_SERVER_BIN_DIR=$KUBERNETES_DIR/server/kubernetes/server/bin
export KUBERNETES_EXECUTABLE_LOCATION=/usr/bin
export KUBERNETES_MASTER_HOSTNAME=$KUBERNETES_CLUSTER_ID-master
export KUBERNETES_SLAVE_HOSTNAME=$KUBERNETES_CLUSTER_ID-slave
export SCRIPT_DIR=$PWD

# detect OS
if [ -f /etc/redhat-release ] || [ -f /etc/redhat-release ]; then
  export OS="redhat"
elif [[ -f /etc/debian_version ]]; then
  export OS="debian"
fi

# Indicates whether the install has succeeded
export is_success=false

install_etcd() {
  if [[ $INSTALLER_TYPE == 'master' ]]; then
    ## download, extract and update etcd binaries ##
    echo 'Installing etcd on master...'
    if [[ $OS == "debian" ]]; then
      cd $KUBERNETES_DOWNLOAD_PATH;
      sudo rm -r etcd-$ETCD_VERSION-linux-amd64 || true;
      etcd_download_url="https://github.com/coreos/etcd/releases/download/$ETCD_VERSION/etcd-$ETCD_VERSION-linux-amd64.tar.gz";
      sudo curl -L $etcd_download_url -o etcd.tar.gz;
      sudo tar xzvf etcd.tar.gz && cd etcd-$ETCD_VERSION-linux-amd64;
      sudo mv -v etcd $ETCD_EXECUTABLE_LOCATION/etcd;
      sudo mv -v etcdctl $ETCD_EXECUTABLE_LOCATION/etcdctl;

      etcd_path=$(which etcd);
      if [[ -z "$etcd_path" ]]; then
        echo 'etcd not installed ...'
        return 1
      else
        echo 'etcd successfully installed ...'
        echo $etcd_path;
        etcd --version;
      fi
    elif [[ $OS == "redhat" ]]; then
      sudo yum -y install etcd
      echo `which etcd`
      echo 'etcd installed correctly'

      echo "updating etcd configs"
      cat << EOF > /etc/etcd/etcd.conf
ETCD_NAME=default
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:$ETCD_PORT"
ETCD_ADVERTISE_CLIENT_URLS="http://localhost:$ETCD_PORT"
EOF
    echo "etcd config updated successfully"

    echo "starting etcd service"
    sudo systemctl start etcd

    fi
  else
    echo "Installing for slave, skipping etcd..."
  fi
}

install_docker() {
  echo "Installing docker version $DOCKER_VERSION ..."
    sudo apt-get -yy update
    echo "deb http://get.docker.com/ubuntu docker main" | sudo tee /etc/apt/sources.list.d/docker.list
    sudo apt-key adv --keyserver pgp.mit.edu --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9
    sudo apt-get -yy update
    sudo apt-get -o Dpkg::Options::='--force-confnew' -yy install lxc-docker-$DOCKER_VERSION
    sudo service docker stop || true
}

install_prereqs() {
  echo "Installing network prereqs on slave..."
  if [[ $OS == "debian" ]]; then
    sudo apt-get install -yy bridge-utils
  elif [[ $OS == "redhat" ]]; then
    sudo yum install -y bridge-utils
  fi
}

clear_network_entities() {
  ## remove the docker0 bridge created by docker daemon
  echo 'stopping docker'
  sudo service docker stop || true
  sudo ip link set dev docker0 down  || true
  sudo brctl delbr docker0 || true
}

download_flannel_release() {
  if [[ $OS == "debian" ]]; then
    echo "Downloading flannel release version: $FLANNEL_VERSION"
    cd $KUBERNETES_DOWNLOAD_PATH
    flannel_download_url="https://github.com/coreos/flannel/releases/download/v$FLANNEL_VERSION/flannel-$FLANNEL_VERSION-linux-amd64.tar.gz";
    sudo curl --max-time 180 -L $flannel_download_url -o flannel.tar.gz;
    sudo tar xzvf flannel.tar.gz && cd flannel-$FLANNEL_VERSION;
    sudo mv -v flanneld $FLANNEL_EXECUTABLE_LOCATION/flanneld;
  elif [[ $OS == "redhat" ]]; then
    sudo yum -y install flannel
    echo `which flanneld`
    echo 'flanneld installed correctly'
  fi
}

update_hosts() {
  echo "Updating /etc/hosts..."
  echo "$MASTER_IP $KUBERNETES_MASTER_HOSTNAME" | sudo tee -a /etc/hosts
  echo "$SLAVE_IP $KUBERNETES_SLAVE_HOSTNAME" | sudo tee -a /etc/hosts
  cat /etc/hosts
}

download_kubernetes_release() {
  ## download and extract kubernetes archive ##
  if [[ $OS == "debian" ]]; then
    echo "Downloading kubernetes release version: $KUBERNETES_RELEASE_VERSION"
    cd $KUBERNETES_DOWNLOAD_PATH
    mkdir -p $KUBERNETES_EXTRACT_DIR
    kubernetes_download_url="https://github.com/GoogleCloudPlatform/kubernetes/releases/download/$KUBERNETES_RELEASE_VERSION/kubernetes.tar.gz";
    sudo curl -L $kubernetes_download_url -o kubernetes.tar.gz;
    sudo tar xzvf kubernetes.tar.gz -C $KUBERNETES_EXTRACT_DIR;
  elif [[ $OS == "redhat" ]]; then
    sudo yum update -y
    sudo tee /etc/yum.repos.d/kubernetes.repo <<-'EOF'
[virt7-docker-common-release]
name=virt7-docker-common-release
baseurl=http://cbs.centos.org/repos/virt7-docker-common-release/x86_64/os/
gpgcheck=0
EOF
    sudo yum -y install --enablerepo=virt7-docker-common-release kubernetes
  fi

}

extract_server_binaries() {
  # extract the kubernetes server binaries ##
  echo "Extracting kubernetes server binaries from $KUBERNETES_DIR"
  cd $KUBERNETES_DIR/server
  sudo su -c "cd $KUBERNETES_DIR/server && tar xzvf $KUBERNETES_DIR/server/kubernetes-server-linux-amd64.tar.gz"
  echo 'Successfully extracted kubernetes server binaries'
}

update_master_binaries() {
  # place binaries in correct folders
  echo 'Updating kubernetes master binaries'
  cd $KUBERNETES_SERVER_BIN_DIR
  sudo cp -vr * $KUBERNETES_EXECUTABLE_LOCATION/
  echo "Successfully updated kubernetes server binaries to $KUBERNETES_EXECUTABLE_LOCATION"
}

copy_master_binaries() {
    echo "Copying binary files for master components"
    sudo cp -vr $KUBERNETES_SERVER_BIN_DIR/kube-apiserver $KUBERNETES_EXECUTABLE_LOCATION/
    sudo cp -vr $KUBERNETES_SERVER_BIN_DIR/kube-controller-manager $KUBERNETES_EXECUTABLE_LOCATION/
    sudo cp -vr $KUBERNETES_SERVER_BIN_DIR/kube-scheduler $KUBERNETES_EXECUTABLE_LOCATION/
    sudo cp -vr $KUBERNETES_SERVER_BIN_DIR/kubectl $KUBERNETES_EXECUTABLE_LOCATION/
}


copy_master_configs() {
  if [[ $OS == "debian" ]]; then
    echo "Copying 'default' files for master components"
      sudo cp -vr $SCRIPT_DIR/config/thirdparty/etcd.conf /etc/init/etcd.conf
      sudo cp -vr $SCRIPT_DIR/config/k8s/kube-apiserver.conf /etc/init/kube-apiserver.conf
      sudo cp -vr $SCRIPT_DIR/config/k8s/kube-scheduler.conf /etc/init/kube-scheduler.conf
      sudo cp -vr $SCRIPT_DIR/config/k8s/kube-controller-manager.conf /etc/init/kube-controller-manager.conf
      sudo cp -vr $SCRIPT_DIR/config/k8s/kube-apiserver /etc/default/kube-apiserver
      sudo cp -vr $SCRIPT_DIR/config/k8s/kube-scheduler /etc/default/kube-scheduler
      sudo cp -vr $SCRIPT_DIR/config/k8s/kube-controller-manager /etc/default/kube-controller-manager
      sudo cp -vr $SCRIPT_DIR/config/thirdparty/etcd /etc/default/etcd
  elif [[ $OS == "redhat" ]]; then
    echo "updating kubernetes configs"
    sed -i "s/--etcd-servers=.*/--etcd-servers=http:\/\/$MASTER_IP:$ETCD_PORT\"/" `grep ETCD_SERVER /etc/kubernetes/* | cut -d ':' -f1`
    #generate_ssl_signing_key
    mkdir -p /etc/pki/kube-apiserver/
    openssl genrsa -out /etc/pki/kube-apiserver/serviceaccount.key 2048
    sed -i '/KUBE_API_ARGS=*/c\KUBE_API_ARGS="--secure-port=0 --service_account_key_file=/etc/pki/kube-apiserver/serviceaccount.key"' /etc/kubernetes/apiserver
    sed -i '/KUBE_CONTROLLER_MANAGER_ARGS=*/c\KUBE_CONTROLLER_MANAGER_ARGS="--service_account_private_key_file=/etc/pki/kube-apiserver/serviceaccount.key"' /etc/kubernetes/controller-manager
    sed -i "s/--insecure-bind-address=.*/--insecure-bind-address=0.0.0.0\"/" `grep API_ADDRESS /etc/kubernetes/* | cut -d ':' -f1`
  fi
}

copy_slave_binaries() {
    echo "Copying binary files for slave components"
    sudo cp -vr $KUBERNETES_SERVER_BIN_DIR/kubelet $KUBERNETES_EXECUTABLE_LOCATION/
    sudo cp -vr $KUBERNETES_SERVER_BIN_DIR/kube-proxy $KUBERNETES_EXECUTABLE_LOCATION/
}

update_slave_configs() {
  if [[ $OS == "redhat" ]]; then
    sed -i s/FLANNEL_ETCD=.*/FLANNEL_ETCD="http:\/\/$MASTER_IP:$ETCD_PORT"/g /etc/sysconfig/flanneld
    sed -i s/#FLANNEL_OPTIONS=.*/FLANNEL_OPTIONS="-iface=$SLAVE_IP"/g /etc/sysconfig/flanneld

    sed -i "/KUBE_API_ADDRESS=*/c\KUBE_API_ADDRESS='"--insecure-bind-address=$MASTER_IP"'" /etc/kubernetes/apiserver
    sed -i "/KUBE_ETCD_SERVERS=*/c\KUBE_ETCD_SERVERS='"--etcd-servers=http:\/\/$MASTER_IP:$ETCD_PORT"'" /etc/kubernetes/apiserver
    sed -i "/KUBE_MASTER=*/c\KUBE_MASTER='"--master=http:\/\/$MASTER_IP:8080"'" /etc/kubernetes/config
    sed -i "/KUBELET_API_SERVER=*/c\KUBELET_API_SERVER='"--api-servers=http:\/\/$MASTER_IP:8080"'" /etc/kubernetes/kubelet
    sed -i '/KUBELET_ADDRESS=*/c\KUBELET_ADDRESS="--address=0.0.0.0"' /etc/kubernetes/kubelet
    sed -i s/KUBELET_HOSTNAME=.*/KUBELET_HOSTNAME="--hostname-override=$SLAVE_IP"/g /etc/kubernetes/kubelet
    sed -i s/KUBELET_ARGS=.*/KUBELET_ARGS="--maximum-dead-containers=0"/g /etc/kubernetes/kubelet
    
  elif [[ $OS == "debian" ]]; then
    sudo cp -vr $SCRIPT_DIR/config/thirdparty/flanneld.conf /etc/init/flanneld.conf
    echo "FLANNELD_OPTS='-etcd-endpoints=http://$MASTER_IP:$ETCD_PORT -iface=$SLAVE_IP -ip-masq=true'" | sudo tee -a /etc/default/flanneld

    sudo cp -vr $SCRIPT_DIR/config/thirdparty/docker.conf /etc/init/docker.conf
    sudo cp -vr $SCRIPT_DIR/config/thirdparty/docker /etc/default/docker

    # update kubelet config
    sudo cp -vr $SCRIPT_DIR/config/k8s/kubelet.conf /etc/init/kubelet.conf
    echo "export KUBERNETES_EXECUTABLE_LOCATION=/usr/bin" | sudo tee -a /etc/default/kubelet
    echo "KUBELET=$KUBERNETES_EXECUTABLE_LOCATION/kubelet" | sudo tee -a /etc/default/kubelet
    echo "KUBELET_OPTS='--address=0.0.0.0 --port=10250 --max-pods=75 --docker_root=/data --hostname_override=$SLAVE_IP --api_servers=http://$MASTER_IP:8080 --enable_server=true --logtostderr=true --v=0 --maximum-dead-containers=10'" | sudo tee -a /etc/default/kubelet

    # update kube-proxy config
    sudo cp -vr $SCRIPT_DIR/config/k8s/kube-proxy.conf /etc/init/kube-proxy.conf
    echo "KUBE_PROXY=$KUBERNETES_EXECUTABLE_LOCATION/kube-proxy" | sudo tee -a  /etc/default/kube-proxy
    echo -e "KUBE_PROXY_OPTS='--master=$MASTER_IP:8080 --logtostderr=true'" | sudo tee -a /etc/default/kube-proxy
    echo "kube-proxy config updated successfully"
  fi
}

remove_redundant_config() {
  # remove the config files for redundant services so that they 
  # dont boot up if server restarts
  if [[ $INSTALLER_TYPE == 'master' ]]; then
    echo 'removing redundant service configs for master ...'

    # removing from /etc/init
    sudo rm -rf /etc/init/kubelet.conf || true
    sudo rm -rf /etc/init/kube-proxy.conf || true

    # removing from /etc/init.d
    sudo rm -rf /etc/init.d/kubelet || true
    sudo rm -rf /etc/init.d/kube-proxy || true

    # removing config from /etc/default
    sudo rm -rf /etc/default/kubelet || true
    sudo rm -rf /etc/default/kube-proxy || true
  else
    echo 'removing redundant service configs for master...'

    # removing from /etc/init
    sudo rm -rf /etc/init/kube-apiserver.conf || true
    sudo rm -rf /etc/init/kube-controller-manager.conf || true
    sudo rm -rf /etc/init/kube-scheduler.conf || true

    # removing from /etc/init.d
    sudo rm -rf /etc/init.d/kube-apiserver || true
    sudo rm -rf /etc/init.d/kube-controller-manager || true
    sudo rm -rf /etc/init.d/kube-scheduler || true

    # removing from /etc/default
    sudo rm -rf /etc/default/kube-apiserver || true
    sudo rm -rf /etc/default/kube-controller-manager || true
    sudo rm -rf /etc/default/kube-scheduler || true
  fi
}

stop_services() {
  # stop any existing services
  if [[ $INSTALLER_TYPE == 'master' ]]; then
    echo 'Stopping master services...'
    sudo service etcd stop || true
    sudo service kube-apiserver stop || true
    sudo service kube-controller-manager stop || true
    sudo service kube-scheduler stop || true
  else
    echo 'Stopping slave services...'
    sudo service flanneld stop || true
    sudo service kubelet stop || true
    sudo service kube-proxy stop || true
    sudo service docker stop || true
  fi
}

start_services() {
  if [[ $INSTALLER_TYPE == 'master' ]]; then
    echo 'Starting master services...'
    if [[ $OS == 'debian' ]]; then
      sudo service etcd start
    ## No need to start kube-apiserver, kube-controller-manager and kube-scheduler
    ## because the upstart scripts boot them up when etcd starts
    elif [[ $OS == 'redhat' ]]; then
      for SERVICES in kube-apiserver kube-controller-manager kube-scheduler; do 
        sudo systemctl start $SERVICES
        sudo systemctl enable $SERVICES
        sudo systemctl status $SERVICES 
      done
    fi
  else
    echo 'Starting slave services...'
    sudo service flanneld start
    sudo service kubelet start
    sudo service kube-proxy start
    #sudo service docker start
  fi
}

update_flanneld_subnet() {
  ## update the key in etcd which determines the subnet that flannel uses
  echo 'Waiting for 5 seconds for etcd to start'
  sleep 5
  if [[ $OS == "debian" ]]; then
    $ETCD_EXECUTABLE_LOCATION/etcdctl --peers=http://$MASTER_IP:$ETCD_PORT set coreos.com/network/config '{"Network":"'"$FLANNEL_SUBNET"'"}'
  elif [[ $OS == "redhat" ]]; then
    $ETCD_EXECUTABLE_LOCATION/etcdctl --peers=http://$MASTER_IP:$ETCD_PORT set /atomic.io/network/config '{"Network":"'"$FLANNEL_SUBNET"'"}'
  fi
  ret=$?
  if [ $ret == 0 ]; then
    echo 'Updated flanneld subnet in etcd'
  else
    echo 'Failed to flanneld subnet in etcd'
  fi  
}

check_service_status() {
  if [[ $INSTALLER_TYPE == 'master' ]]; then
    sudo service etcd status
    sudo service kube-apiserver status
    sudo service kube-controller-manager status
    sudo service kube-scheduler status

    echo 'install of kube-master successful'
    is_success=true
  else
    echo 'Checking slave services status...'
    sudo service kubelet status
    sudo service kube-proxy status

    echo 'install of kube-slave successful'
    is_success=true
  fi
}

before_exit() {
  if [ "$is_success" == true ]; then
    echo "Script Completed Successfully";
  else
    echo "Script executing failed";
  fi
}

trap before_exit EXIT
install_prereqs

trap before_exit EXIT
clear_network_entities


trap before_exit EXIT
update_hosts

trap before_exit EXIT
stop_services

trap before_exit EXIT
remove_redundant_config

trap before_exit EXIT
download_kubernetes_release

trap before_exit EXIT
if [[ $OS == "debian" ]]; then
  extract_server_binaries
fi

if [[ $INSTALLER_TYPE == 'slave' ]]; then
  trap before_exit EXIT
  if [[ $OS == "debian" ]]; then
    install_docker
  fi

  trap before_exit EXIT
  download_flannel_release

  trap before_exit EXIT
  if [[ $OS == "debian" ]]; then
    copy_slave_binaries
  fi

  trap before_exit EXIT
  update_slave_configs

else
  trap before_exit EXIT
  if [[ $OS == "debian" ]]; then
    copy_master_binaries
  fi

  trap before_exit EXIT
  copy_master_configs

  trap before_exit EXIT
  install_etcd

  trap before_exit EXIT
  update_flanneld_subnet
fi

trap before_exit EXIT
start_services

trap before_exit EXIT
check_service_status

echo "Kubernetes $INSTALLER_TYPE install completed"
