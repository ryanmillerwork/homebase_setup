if [[ -z $DISPLAY ]] && [[ $(tty) = /dev/tty1 ]]; then exec /usr/bin/startx /usr/local/bin/start-stim-fullscreen.sh -- -s 0 -dpms ; fi
