# Router - workflow

Just a repo you clone into freshly installed [Armbian minimal image](http://dl.armbian.com/orangepizero3/Trixie_current_minimal), and run install.sh :).
Remember to add uninstall option to ease the developement process and avoid unneccesary SD card flashes (It has one life too). 

```bash
├── install.sh
├── scripts
│   ├── dnsmasq.sh
│   └── ...
└── uninstall.sh
```
**install.sh** - just call each install script from _install_scripts_ directory.  
**scripts/\*.sh** - Install desired module along with all configs, _-D_ flag or similar for uninstallation.  
**uninstall.sh** - Execute each script with _-D_ flag.   

Script template:  
```bash
#!/bin/bash

install=true

while getopts "D" flg; do
	case "${flg}" in
		D) install=false
	esac
done

if $install; then
	# all work here
else
	# uninstall
fi
```

Git workflow:  
1. Fork main repo (github + fork button)  
2. Add remote for your fork
3. Always push to your fork and pull from origin
4. Lets do one commit = one functionality (done and tested)  
5. When functionality is done create pull request (github + compare and PR)  
6. Review and approve or request changes on other people PR's :)

Useful git commands:  
```bash
git remote add remote_name your_fork_url
git remote -v // Show all remotes (urls for repos)

git config --global pull.rebase true // Use rebase instead of merge by default
git pull origin branch_here // Pull (fetch + merge/rebase) changes from remote

git branch my_branch // Create branch
git switch my_branch
git branch // show actual branch

git diff filename_here_or_empty_to_diff_workdir // Show changes done to file
git add filename_here // Stage file
git restore --staged filename_gere // Unstage file
git status // Show modified files, staged, new, etc
git commit -m "some message" // Commit staged files
git commit --amend // Add changes to recent commit (not create new one) useful when we forget sth
git log // Show commit history

git push -u remote_name branch_here // Push changes to remote (do not push to main :p)
```

# TODO week 1
1. Default configurations   
- [x] hostapd on wlan0 (SSID: "test", PASS: "dupa1234")
- [x] Lighttpd + TLS (self-signed keys + default website)
- [x] dnsmasq as dhcp server for lan (192.168.0.0/24 with 192.168.0.1 for wlan0)
- [x] eth0 as WAN interface (dhcp client)

2. Basic firewall  
Remember about udp!   
- [x] Block all incomming connections from public network
- [x] Enable routing from private (wlan0) to public (eth0) network with NAT
- [x] Enable all inside private network
- [x] Enable outgoing dhcp, dns and ntp for public network

# TODO week 2 + 3
1. Web interface (html + css)  
- [ ] main page showing core parameters i.e in/out interface, ip addresses, hotspot info  
- [ ] login page  
- [ ] Ability to modify params and apply button (POST request)  

2. Backend (python as cgi)
- [ ] generate main page (fill template with currently used parameters)  
- [ ] user authentication and cookie set  
- [ ] __validate all params send by client!!!__ and pass them to proper script

3. Integration with system services
- [ ] Enable cgi in lighttpd config
- [ ] One file with config prams for generation services config files  
- [ ] GNU stow as config manager  
- [ ] Scripts for backend to manage configs  
- [ ] Watchdog service to restore default settings when user config crashes  
