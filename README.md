## 关于serv00的一些快捷方法，本人自用的。
## 面板
```
bash <(curl -s https://raw.githubusercontent.com/moyu-hax/serv00_neza/main/install-dashboard.sh)
```
## 被控端
```
bash <(curl -s https://raw.githubusercontent.com/moyu-hax/serv00_neza/main/install-agent.sh)
```
## 重启指令
```
nohup ~/.nezha-agent/start.sh >/dev/null 2>&1 &
```
## 一键节点直连
```
 git clone -b direct https://github.com/k0baya/x-for-serv00 ~/direct-xray
```
```
chmod +x ~/direct-xray/start.sh && bash ~/direct-xray/start.sh 
```
```
bash ~/direct-xray/start.sh >/dev/null 2>&1
```
