@{
    # 规则配置：安装器需要 Write-Host；界面/颜色常量等风格问题不阻断 CI
    Severity = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingPositionalParameters',
        'PSMissingModuleManifestField',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSReviewUnusedParameter',
        'PSAvoidAssignmentToAutomaticVariable',
        'PSAvoidGlobalAliases',
        'PSAvoidUsingInvokeExpression',
        'PSUseToExportFieldsInManifest'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('5.1')
        }
    }
}
