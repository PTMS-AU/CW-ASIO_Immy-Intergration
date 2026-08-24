@{
    # Rules excluded for reasons specific to how ImmyBot runs these scripts.
    ExcludeRules = @(
        # Write-Host IS the output channel in ImmyBot. Script output is captured
        # and shown in the integration/deployment log; Write-Output would be
        # interpreted as a return value and corrupt what detection and the
        # capability blocks hand back.
        'PSAvoidUsingWriteHost',

        # Uninstall-CWPlatform.ps1 consumes $UninstallPassword as a plain string
        # because ImmyBot's software entry supplies it that way. Not our contract
        # to change. (It is now an ambient variable rather than a declared
        # parameter — see the note in that script — so these rules may no longer
        # fire on it. Retained so the exclusion does not have to be rediscovered
        # if the shape changes back.)
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
