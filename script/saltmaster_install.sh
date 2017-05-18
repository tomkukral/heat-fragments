
echo "Installing salt master ..."
aptget_wrapper install -y reclass git
aptget_wrapper install -y salt-master

[ ! -d /root/.ssh ] && mkdir -p /root/.ssh
cat << 'EOF' > /root/.ssh/id_rsa
$private_key
EOF
chmod 400 /root/.ssh/id_rsa

cat << 'EOF' > /etc/salt/master.d/master.conf
file_roots:
  base:
  - /usr/share/salt-formulas/env
pillar_opts: False
open_mode: True
reclass: &reclass
  storage_type: yaml_fs
  inventory_base_uri: /srv/salt/reclass
ext_pillar:
  - reclass: *reclass
master_tops:
  reclass: *reclass
EOF

echo "Configuring reclass ..."
ssh-keyscan -H github.com >> ~/.ssh/known_hosts || wait_condition_send "FAILURE" "Failed to scan github.com key."
git clone -b $reclass_branch --recurse-submodules $reclass_address /srv/salt/reclass || wait_condition_send "ERROR: failed to clone reclass"
mkdir -p /srv/salt/reclass/classes/service

mkdir -p /srv/salt/reclass/nodes/_generated

cat << 'EOF' > /srv/salt/reclass/nodes/_generated/$node_hostname.$node_domain.yml
classes:
- cluster.$cluster_name.infra.config
parameters:
  _param:
    linux_system_codename: xenial
    reclass_data_revision: $reclass_branch
    reclass_data_repository: $reclass_address
    cluster_name: $cluster_name
    cluster_domain: $node_domain
  linux:
    system:
      name: $node_hostname
      domain: $node_domain
EOF

FORMULA_PATH=${FORMULA_PATH:-/usr/share/salt-formulas}
FORMULA_REPOSITORY=${FORMULA_REPOSITORY:-deb [arch=amd64] http://apt-mk.mirantis.com/xenial testing salt}
FORMULA_GPG=${FORMULA_GPG:-http://apt-mk.mirantis.com/public.gpg}

echo "Configuring salt master formulas ..."
which wget > /dev/null || (aptget_wrapper update; aptget_wrapper install -y wget)

echo "${FORMULA_REPOSITORY}" > /etc/apt/sources.list.d/mcp_salt.list
wget -O - "${FORMULA_GPG}" | apt-key add - || wait_condition_send "FAILURE" "Failed to add formula key."

aptget_wrapper clean
aptget_wrapper update

[ ! -d /srv/salt/reclass/classes/service ] && mkdir -p /srv/salt/reclass/classes/service

declare -a formula_services=("linux" "reclass" "salt" "openssh" "ntp" "git" "nginx" "collectd" "sensu" "heka" "sphinx" "keystone" "mysql" "grafana" "haproxy" "rsyslog" "horizon" "telegraf" "prometheus")

echo -e "\nInstalling all required salt formulas\n"
aptget_wrapper install -y "${formula_services[@]/#/salt-formula-}"

for formula_service in "${formula_services[@]}"; do
    echo -e "\nLink service metadata for formula ${formula_service} ...\n"
    [ ! -L "/srv/salt/reclass/classes/service/${formula_service}" ] && \
        ln -s ${FORMULA_PATH}/reclass/service/${formula_service} /srv/salt/reclass/classes/service/${formula_service}
done

[ ! -d /srv/salt/env ] && mkdir -p /srv/salt/env
[ ! -L /srv/salt/env/prd ] && ln -s ${FORMULA_PATH}/env /srv/salt/env/prd

[ ! -d /etc/reclass ] && mkdir /etc/reclass
cat << 'EOF' > /etc/reclass/reclass-config.yml
storage_type: yaml_fs
pretty_print: True
output: yaml
inventory_base_uri: /srv/salt/reclass
EOF

echo "Restarting salt-master service ..."
systemctl restart salt-master || wait_condition_send "FAILURE" "Failed to restart salt-master service."

echo "Running the resto of states ..."
run_states=("linux,openssh" "reclass" "salt.master.service" "salt")
for state in "${run_states[@]}"
do
  salt-call --no-color state.sls "$state" -l info || wait_condition_send "FAILURE" "Salt state $state run failed."
done

echo "Showing known models ..."
reclass-salt --top || wait_condition_send "FAILURE" "Reclass-salt command run failed."
