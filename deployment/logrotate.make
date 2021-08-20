# If `cron.daily/logrotate` exists, we better move it over to `cron.hourly`, so that we can do hourly log rotations
ifneq ($(wildcard /etc/cron.daily/logrotate),)
/etc/cron.hourly/logrotate: /etc/cron.daily/logrotate
# Use `dpkg-divert`, if possible
ifneq ($(shell which dpkg-divert 2>/dev/null),)
	sudo dpkg-divert --add --rename --divert /etc/cron.hourly/logrotate /etc/cron.daily/logrotate
else
	sudo mv $< $@
endif
up: /etc/cron.hourly/logrotate
endif

# Also, we need to override systemd's logrotate.timer if it exists, to run hourly
ifneq ($(wildcard /lib/systemd/system/logrotate.timer),)
/lib/systemd/system/logrotate.timer.old: /lib/systemd/system/logrotate.timer
	sudo cp $< $@
	sed -e 's/^OnCalendar=.*/OnCalendar=hourly/' -e 's/^AccuracySec=.*/AccuracySec=30m/' <$@ | sudo tee $< >/dev/null
	sudo touch $@
    sudo systemctl daemon-reload
up: /lib/systemd/system/logrotate.timer.old
endif

