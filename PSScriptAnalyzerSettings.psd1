@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The watcher is an interactive terminal display by design.
        'PSAvoidUsingWriteHost'
    )
}
