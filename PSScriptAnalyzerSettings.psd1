@{
    # Rules excluded for reasons specific to how ImmyBot runs these scripts.
    ExcludeRules = @(
        # Write-Host IS the output channel in ImmyBot. Script output is captured
        # and shown in the integration/deployment log; Write-Output would be
        # interpreted as a return value and corrupt what detection and the
        # capability blocks hand back.
        'PSAvoidUsingWriteHost',

        # Uninstall-Asio.ps1 takes -UninstallPassword as a plain string because
        # ImmyBot's software entry passes it that way. Not our contract to change.
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText',

        # The capability scriptblocks are invoked by ImmyBot, not by a caller who
        # could pass -WhatIf, and their names are fixed by the interface.
        'PSUseShouldProcessForStateChangingFunctions',

        # Variables consumed only through $using: inside Invoke-ImmyCommand read
        # as write-only to the analyser.
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
