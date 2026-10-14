#LOGS:
sudo cat /myapps/setup/install.log
sudo tail -f /myapps/setup/install.log # (FOLLOW LIVE)
sudo cat /myapps/setup/install.log | curl -s -F "content=<-" https://dpaste.com/api/v2/

#FILEBROWSER:
sudo cat /myapps/filebrowser/filebrowser.out.log | grep -i 'admin password'

#EARLYOOM:
journalctl -u earlyoom --since "2 hours ago" # logs "sending SIGTERM to process NNNN"
journalctl -k | grep -i -E 'oom|killed process' # kernel OOM killer, if it got that far

#RESET:
cd ~ # nicht in /myapps stehen, das wird gleich gelöscht
sudo supervisorctl stop all
sudo rm -R -v /myapps
sudo rm -v /etc/supervisor/conf.d/*
sudo supervisorctl update # Supervisor vergisst die alten Programme
curl -fsSL https://raw.githubusercontent.com/boustanihani/pocketbase-lightsail-hosting/main/install.sh | sudo bash
