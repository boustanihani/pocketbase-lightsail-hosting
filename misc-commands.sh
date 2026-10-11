
sudo cat /myapps/setup/install.log

sudo tail -f /myapps/setup/install.log # (FOLLOW LIVE)

sudo cat /myapps/setup/install.log | curl -s -F "content=<-" https://dpaste.com/api/v2/

sudo cat /myapps/filebrowser/filebrowser.out.log | grep -i 'admin password'

journalctl -u earlyoom --since "2 hours ago" # logs "sending SIGTERM to process NNNN"
journalctl -k | grep -i -E 'oom|killed process' # kernel OOM killer, if it got that far

