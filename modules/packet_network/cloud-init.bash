#!/usr/bin/env bash
# vim:filetype=sh
set -o errexit
set -o pipefail
shopt -s nullglob

main() {
  if [[ ! "${QUIET}" ]]; then
    set -o xtrace
  fi

  logger 'msg="beginning cloud-init fun"'

  : "${ETCDIR:=/etc}"
  : "${RUNDIR:=/var/tmp/travis-run.d}"
  : "${USRLOCAL:=/usr/local}"
  : "${VARTMP:=/var/tmp}"

  export DEBIAN_FRONTEND=noninteractive
  chown nobody:nogroup "${VARTMP}"
  chmod 0777 "${VARTMP}"

  mkdir -p "${RUNDIR}"
  if [[ ! -f "${RUNDIR}/instance-hostname.tmpl" ]]; then
    echo "___INSTANCE_ID___-$(hostname)" >"${RUNDIR}/instance-hostname.tmpl"
  fi

  for substep in \
    tfw \
    travis_user \
    sysctl \
    networking \
    duo \
    raid; do
    logger "msg=\"running setup\" substep=\"${substep}\""
    "__setup_${substep}"
  done
}

__setup_tfw() {
  logger "msg=\"running tfw bootstrap\""
  tfw bootstrap

  chown -R root:root "${ETCDIR}/sudoers" "${ETCDIR}/sudoers.d"

  logger "msg=\"running tfw admin-bootstrap\""
  tfw admin-bootstrap

  systemctl restart sshd || true
}

__setup_travis_user() {
  if ! getent passwd travis &>/dev/null; then
    useradd travis
  fi

  chown -R travis:travis "${RUNDIR}"
}

__setup_sysctl() {
  echo 1048576 >/proc/sys/fs/aio-max-nr
  sysctl -w fs.aio-max-nr=1048576

  echo 1 >/proc/sys/net/ipv4/ip_forward
  sysctl -w net.ipv4.ip_forward=1
}

__setup_networking() {
  for key in autosave_v{4,6}; do
    echo "iptables-persistent iptables-persistent/${key} boolean true" |
      debconf-set-selections
  done

  apt-get install -yqq iptables-persistent

  local pub_iface elastic_ip loc_iface loc_subnet
  pub_iface="$(__find_public_interface)"
  elastic_ip="$(__find_elastic_ip)"
  loc_iface="$(__find_local_interface)"
  loc_subnet="$(__find_local_subnet)"

  iptables -P FORWARD ACCEPT

  if [[ -n "${elastic_ip}" ]]; then
    if ip address add "${elastic_ip}/32" dev lo; then
      iptables -t nat -A POSTROUTING -o "${pub_iface}" -j SNAT --to "${elastic_ip}"
    fi
  fi

  if ! iptables -t nat -C POSTROUTING -j MASQUERADE; then
    iptables -t nat -A POSTROUTING -j MASQUERADE
  fi

  if ! iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; then
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  fi

  if ! iptables -C INPUT --in-interface "${loc_iface}" --src ! "${loc_subnet}" -j LOG --log-prefix "SPOOF"; then
    iptables -A INPUT --in-interface "${loc_iface}" --src ! "${loc_subnet}" -j LOG --log-prefix "SPOOF"
    if ! iptables -C INPUT --in-interface "${loc_iface}" --src ! "${loc_subnet}" -j DROP; then
      iptables -A INPUT --in-interface "${loc_iface}" --src ! "${loc_subnet}" -j DROP
    fi
  fi
}

__find_public_interface() {
  local iface=bond0
  iface="$(ip -o addr show | grep -vE 'inet (172|127|10|192)\.' | grep -v inet6 |
    awk '{ print $2 }' | grep -v '^lo$' | head -n 1)"
  echo "${iface:-bond0}"
}

__find_local_interface() {
  local iface=enp1s0f1
  subnet="$(ip -o addr show | grep -v inet6 | grep -v " lo " | grep -v "bond" |
    grep -v "docker" | awk '{ print $2}')"
  echo "${iface:-enp1s0f1}"
}

__find_local_subnet() {
  local subnet="192.168.1.1/24"
  subnet="$(ip -o addr show "$(__find_local_interface)" | awk '{ print $4}')"
  echo "${subnet:-"192.168.0.1/24"}"
}

__find_elastic_ip() {
  eval "$(tfw printenv travis-network)"
  echo "${TRAVIS_NETWORK_ELASTIC_IP}"
}

__setup_duo() {
  logger "msg=\"running tfw admin-duo\""
  tfw admin-duo
}

__setup_raid() {
  logger "msg=\"running tfw admin-raid\""
  tfw admin-raid
}

main "$@"
