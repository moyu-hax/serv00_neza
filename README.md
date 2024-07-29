面板
```
bash <(curl -s https://raw.githubusercontent.com/moyu-hax/serv00_neza/main/install-dashboard.sh)
```
被控端
```
bash <(curl -s https://raw.githubusercontent.com/moyu-hax/serv00_neza/main/install-agent.sh)
```
重启指令
```
nohup /home/$USER/.nezha-agent/start.sh >/dev/null 2>&1 &
