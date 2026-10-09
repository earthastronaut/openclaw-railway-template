# Interactive non-login shells do not read /etc/profile.
[ -r /etc/profile.d/container-env.sh ] && . /etc/profile.d/container-env.sh
[ -r /etc/profile.d/openclaw.sh ] && . /etc/profile.d/openclaw.sh
