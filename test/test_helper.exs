# Disable GPG signing and other interactive prompts for all git commands in tests.
# Setting GIT_CONFIG_GLOBAL to /dev/null prevents user-level gitconfig
# (which may have gpg signing, 1Password agent, etc.) from interfering.
System.put_env("GIT_TERMINAL_PROMPT", "0")
System.put_env("GIT_CONFIG_NOSYSTEM", "1")
System.put_env("GIT_CONFIG_GLOBAL", "/dev/null")

ExUnit.start()
