
sudo cat /var/log/cloud-init-output.log

sudo tail -f /var/log/cloud-init-output.log # (FOLLOW LIVE)

sudo cat /var/log/cloud-init-output.log | curl -s -F "content=<-" https://dpaste.com/api/v2/

sudo cat /myapps/filebrowser/filebrowser.err.log | grep -i password

journalctl -u earlyoom --since "2 hours ago" # logs "sending SIGTERM to process NNNN"
journalctl -k | grep -i -E 'oom|killed process' # kernel OOM killer, if it got that far


