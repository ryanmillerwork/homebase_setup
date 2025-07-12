# ~/.bash_profile  (or whatever file autologin on tty1 executes)

if [[ -z $DISPLAY ]] && [[ $(tty) == /dev/tty1 ]]; then
    # 1. seatd-launch → opens the seat for libseat / logind
    # 2. -s          → turn VT hot-keys back on
    # 3. --          → everything after this is *your* program + its args
    exec /usr/bin/seatd-launch cage -s -- /usr/local/bin/start-stim-fullscreen.sh 0 -dpms
fi
