#!/bin/sh
# Ubuntu Server 18.04
# AWS EC2 の ステップ3: インスタンスの詳細の設定 高度な詳細 > ユーザーデータ に貼り付けることで、
# インスタンス起動時にsymbol-testnet-bootstrapのpeerノードのセットアップを行います。
# また、動作の確認用に最新ブロック高を外部へ公開するサービスも動作させます。
# http://__ip_addr__:50080/height.txt でブロック高を確認できます。
#
# 次の作業を行います。
# * ノード動作用ユーザの作成
# * ssh接続ポートの変更
# * docker,docker-composeのインストール
# * symbol-testnet-bootstrapのpeer-assemblyのdocker-composeをサービス化
# * 任意のfriendly_nameを設定(変数に値を入れてください)
# * 任意のhostを設定(変数に値を入れてください)
# * (既存ノードを接続先として取得して設定)
# * 最新のブロック高を外部に公開するサービスのセットアップ
#
# セキュリティグループでは次のポートを公開してください。
# *  7900 peerノード間の通信用
# * 50022 sshd (変数で任意に変更可)
# * 50080 ブロック高公開用 (変数で任意に変更可)
USER=symbol
PSWD=symbol
SSHD_PORT=50022
HTTPD_PORT=50080
DOCKER_COMPOSE_VER=1.25.4
BOOTSTRAP_TAG=0.9.2.1-beta3
FRIENDLY_NAME=
NODE_HOST=
GATEWAY=http://api-xym-harvest-20.ap-northeast-1.nemtech.network

# sshdの接続ポート変更
/bin/sed -i -e "s/^#Port 22$/Port $SSHD_PORT/" /etc/ssh/sshd_config
systemctl restart sshd

# ノード用ユーザ作成
# Ubuntu向け {
adduser --disabled-password --gecos "" "$USER"
echo "$USER:$PSWD" | chpasswd
usermod -G wheel "$USER"
# }
# CentOS向け {
# useradd "$USER" -c ""
# echo "$PSWD" | passwd --stdin "$USER"
# usermod -G wheel "$USER"
# }

# パッケージを最新へアップデート
# Ubuntu向け {
apt-get update -y && apt-get upgrade -y
# }
# CentOS向け {
# yum upgrade -y
# }

# dockerのインストールとサービス開始
# Ubuntu向け {
apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update -y && apt-get install -y docker-ce
# }
# CentOS向け {
# yum remove -y docker \
#               docker-client \
#               docker-client-latest \
#               docker-common \
#               docker-latest \
#               docker-latest-logrotate \
#               docker-logrotate \
#               docker-engine
# yum install -y \
#   yum-utils \
#   device-mapper-persistent-data \
#   lvm2
# yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
# yum install -y \
#   http://mirror.centos.org/centos/7/extras/x86_64/Packages/container-selinux-2.68-1.el7.noarch.rpm \
#   docker-ce docker-ce-cli containerd.io
# }

# docker設定
usermod -a -G docker "$USER"
## コンテナのログ肥大化回避のため古いログは100MBごと3つまででローテーション
echo '{"userns-remap":"default","log-driver":"json-file","log-opts":{"max-size":"100m","max-file":"3"}}' > /etc/docker/daemon.json
systemctl restart docker
sed -Ei.bak "/dockremap:/,/:/ s/[0-9]+/$(id -u symbol)/" /etc/subuid
sed -Ei.bak "/dockremap:/,/:/ s/[0-9]+/$(id -g symbol)/" /etc/subgid
systemctl restart docker

# docker-composeのインストール
curl -L https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VER/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# docker info
# docker-compose --version

# ホームディレクトリへ移動
cd /home/$USER

# symbolノードブートストラップを取得
curl -L https://github.com/nemfoundation/symbol-testnet-bootstrap/archive/$BOOTSTRAP_TAG.tar.gz | tar zx
chown -R $USER: symbol-testnet-bootstrap-$BOOTSTRAP_TAG
cd symbol-testnet-bootstrap-$BOOTSTRAP_TAG/peer-assembly

# knownPeersを取得して設定ファイルを生成
#   リポジトリに入っている設定では都合が悪い場合に有効にしてください。
#   https://github.com/nemfoundation/symbol-testnet-bootstrap/blob/master/peer-assembly/peer-node/userconfig/resources/peers-p2p.json
# curl -o /usr/bin/jq http://stedolan.github.io/jq/download/linux64/jq
# chmod +x /usr/bin/jq
# curl -s $GATEWAY/node/peers \
#   | jq '.[] | {publicKey:.publicKey,endpoint:{host:.host,port:7900},metadata:{name:.friendlyName,roles:"Peer"}}' \
#   | jq -s '{knownPeers:.}' \
#   > peer-node/userconfig/resources/peers-p2p.json
# chown "$USER": peer-node/userconfig/resources/peers-p2p.json

# 設定ファイルの書き換えと更新
#   設定ファイル生成だけ先に済ませる
docker-compose -f docker-compose.yaml up --build generate-raw-addresses store-addresses update_vars
if [ -n "$FRIENDLY_NAME" ]; then
  sed -i.bak "/friendly_name/ s/[0-9A-Z]\{8\}/$FRIENDLY_NAME/" peer-node/config-input.yaml
  # 設定ファイルの適用
  docker-compose -f docker-compose.yaml up --build update_vars
fi
if [ -n "$NODE_HOST" ]; then
  mv peer-node/userconfig/resources/config-node.properties.template{,.bak}
  tr -d \\r < peer-node/userconfig/resources/config-node.properties.template.bak | sed "/^host/ s/$/$NODE_HOST/" > peer-node/userconfig/resources/config-node.properties.template
fi

# symbolノードを常時起動させる設定
# User=rootなのはDockerのマウントしたボリュームのオーナー問題を手抜き解決するため
cat << __EOD__ > /etc/systemd/system/symbol.service
[Unit]
Description=Symbol Node Daemon
After=docker.service

[Service]
Type=simple
User=$USER

WorkingDirectory=/home/$USER/symbol-testnet-bootstrap-$BOOTSTRAP_TAG/peer-assembly
Environment=COMPOSE_FILE=/home/$USER/symbol-testnet-bootstrap-$BOOTSTRAP_TAG/peer-assembly/docker-compose.yaml

ExecStartPre=/usr/local/bin/docker-compose -f \$COMPOSE_FILE rm -v -f
ExecStartPre=/usr/local/bin/docker-compose -f \$COMPOSE_FILE down

ExecStart=/usr/local/bin/docker-compose -f \$COMPOSE_FILE up --build
ExecStop=/usr/local/bin/docker-compose -f \$COMPOSE_FILE stop

ExecStopPost=/usr/local/bin/docker-compose -f \$COMPOSE_FILE rm -v -f
ExecStopPost=/usr/local/bin/docker-compose -f \$COMPOSE_FILE down

ExecReload=/usr/local/bin/docker-compose -f \$COMPOSE_FILE restart

Restart=always
RestartSec=120s

[Install]
WantedBy=multi-user.target
__EOD__

# symbolサービスログ確認用
# journalctl -fu symbol

# symbolノードのブロック高情報をファイルから取り出してheight.txtとして書き込むスクリプト
cat << \__EOD__ > health-check.sh
#!/bin/bash
cd `dirname $0`
while true; do
  echo "ibase=16;$(cat data/index.dat | xxd -p | fold -w2 | tac | tr -d '\n' | tr '[:lower:]' '[:upper:]')" \
    | bc \
    > tmp/height.txt
  cat tmp/height.txt
  sleep 20
done
__EOD__
chmod +x health-check.sh && chown "$USER": health-check.sh

# symbolノードのブロック高情報を公開するためのサービス
cat << __EOD__ > /etc/systemd/system/sym-height.service
[Unit]
Description=Catapult Node simple health check
After=symbol.service

[Service]
Type=simple
User=$USER

WorkingDirectory=/home/$USER/symbol-testnet-bootstrap-$BOOTSTRAP_TAG/peer-assembly

ExecStartPre=/usr/bin/docker run --rm --name sym-height -t -v /home/$USER/symbol-testnet-bootstrap-$BOOTSTRAP_TAG/peer-assembly/tmp:/var/www/localhost/htdocs:ro -p $HTTPD_PORT:80 -d sebp/lighttpd

ExecStart=/home/$USER/symbol-testnet-bootstrap-$BOOTSTRAP_TAG/peer-assembly/health-check.sh

ExecStopPost=/usr/bin/docker stop sym-height

Restart=always
RestartSec=120s

[Install]
WantedBy=multi-user.target
__EOD__

# ブートストラップの常時起動設定とサービスの開始
systemctl daemon-reload
systemctl enable symbol && systemctl start symbol
systemctl enable sym-height && systemctl start sym-height

# Ubuntu向け {
apt-get clean -y && apt-get autoremove -y
dpkg -l 'linux-image-*' | sed '/^ii/!d;/'"$(uname -r | sed "s/\(.*\)-\([^0-9]\+\)/\1/")"'/d;s/^[^ ]* [^ ]* \([^ ]*\).*/\1/;/[0-9]/!d' | xargs sudo apt-get -y purge
update-grub
# }

# CentOS向け {
# # パッケージマネージャキャッシュ削除
# yum clean all
# # 古いカーネルを削除
# package-cleanup --oldkernels --count=1 -y
# }