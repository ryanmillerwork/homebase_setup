if [[ -z $DISPLAY ]] && [[ $(tty) == /dev/tty1 ]]; then
    exec /usr/bin/cage -s -- /usr/local/bin/start-stim-fullscreen.sh 0 -dpms
fi
