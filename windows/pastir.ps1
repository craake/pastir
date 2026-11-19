# pastir launcher for PowerShell. install.sh fills in __DISTRO__ / __PASTIR__ and puts this
# into your PowerShell profile automatically; you only need to copy it by hand if that failed.
#
#   pastir -C ~/projects/myapp "Create relevant .gitignore for this project"
#   pastir -C C:\code\myapp "..."        # Windows paths work too (slower: files live on /mnt/c)
#
# Arguments are base64-encoded on the way into WSL: PowerShell 7.4+ rewrites a leading `~` in
# native-command arguments to C:\Users\<you>, and wsl.exe mangles quotes and apostrophes.
function pastir {
    $enc = @(foreach ($a in $args) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$a)) })
    wsl.exe -d '__DISTRO__' -e '__PASTIR__' --args-b64 @enc
}
