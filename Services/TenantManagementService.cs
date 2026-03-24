namespace BizApps.DemoHub.Portal.API.Services
{
    public class TenantManagementService : ITenantManagementService
    {
        private readonly ILoggerService loggerService;
        private readonly ITraceService traceService;
        private readonly IMetricService metricService;
        private readonly IDemoHubRequestContext demoHubRequestContext;
        private readonly IConfigurationManagerBase configurationManager;
        private readonly IMsGraphClient msGraphClient;
        private readonly IUnitOfWork unitOfWork;
        private const string UserRequiredLicenseMissing = "Some of the users ({0}) are missing required licenses. To continue, please give the required license according to the license requirements matrix at https://aka.ms/tstenantusers to the new users.";
        private const string UserNotExistInTenant = "Some of the required users do not exist in this tenant. To proceed, please create the required user accounts and ensure they are enabled. Once the user accounts ({0}) are properly set up, you can try creating the demo environment again. ";
        private const string NewUserCreatedInTenant = "Required user(s) ({0}) were missing from your tenant. These users have now been created; however, they do not have the required licenses. To continue, please give the required license according to the license requirements matrix at https://aka.ms/tstenantusers to the new users.";
        private const string UserDisabledInTenant = "The required users ({0}) are present in the tenant; however, they are currently not in the 'enabled' state. To proceed, please update the properties of each user account to enable them. Once the necessary changes are made, you can try creating the demo environment again.";
        private const string LicenseAssignationFailedCommonHeading = "License assignation failed for some of the personas. To procceed, please create/enable and assign proper licenses for below users. ";
        private const string LicenseAssignationFailedPerPersonaMessage = "User : {0} is missing license {1}";
        private const string TryAgainMessage = "Try again";

        public TenantManagementService(ILoggerService loggerService,
            ITraceService traceService,
            IMetricService metricService,
            IMsGraphClient msGraphClient,
            IDemoHubRequestContext demoHubRequestContext,
            IConfigurationManagerBase configurationManager,
            IUnitOfWork unitOfWork)
        {
            this.loggerService = loggerService;
            this.traceService = traceService;
            this.metricService = metricService;
            this.msGraphClient = msGraphClient;
            this.demoHubRequestContext = demoHubRequestContext;
            this.configurationManager = configurationManager;
            this.unitOfWork = unitOfWork;
        }

        public async Task<IEnumerable<TenantUserAccountStatus>> GetTenantUserAccountStatusAsync(IEnumerable<DemoPersonasDto>? personaListForCurrentTenant)
        {
            var dimensions = new Dictionary<IDimension, string>();
            string correlationId = $"Correlation Id: {demoHubRequestContext?.CorrelationId}.";
            loggerService.Write(LogLevel.Information, $"{correlationId} {nameof(GetTenantUserAccountStatusAsync)}.");

            string domainName = demoHubRequestContext.UserDetails.Upn.GetDomainName();

            List<TenantUserAccountStatus> listOfAccounts = new List<TenantUserAccountStatus>();

            var userListQuery = GetConcatedUserListWithDomain(personaListForCurrentTenant, domainName);
            var demoAccountsInformation = await msGraphClient.GetAccountsDetails<Dictionary<string, object>>(userListQuery);

            // FIX 1: Guard against null before deserializing so Find() below never throws NullReferenceException,
            // which was being caught and silently turned into the generic "Try again" error.
            var userCallResponse = demoAccountsInformation
                ?.GetValueOrDefault("value")
                ?.ToString()
                ?.DeserializeToObject<List<TenantUserAccountDeatilsGraphResponse>>()
                ?? new List<TenantUserAccountDeatilsGraphResponse>();

            foreach (var user in personaListForCurrentTenant)
            {
                TenantUserAccountStatus accountStatus = new TenantUserAccountStatus();
                accountStatus.UPN = user.PersonaUPN + domainName;
                accountStatus.PersonaID = user.PersonaId;
                TenantUserAccountDeatilsGraphResponse response = userCallResponse.Find(x => x.UserPrincipalName.Equals(accountStatus.UPN, StringComparison.OrdinalIgnoreCase));
                if (response != null)
                {
                    accountStatus.IsExists = true;
                    accountStatus.IsActive = response.AccountEnabled;
                }
                listOfAccounts.Add(accountStatus);
            }

            LogAndSetMetrics(
                           dimensions,
                           Convert.ToString(HttpStatusCode.OK),
                           nameof(GetTenantUserAccountStatusAsync),
                           $"{correlationId} {nameof(GetTenantUserAccountStatusAsync)}. Graph call worked fine.",
                           Metrics.GraphAPICounter,
                           LogLevel.Information);

            return listOfAccounts;
        }

        /// <summary>
        /// Alternate of System.Web.Security.Membership.GeneratePassword which is not present in aspnetcore 
        /// https://stackoverflow.com/questions/38995379/alternative-to-system-web-security-membership-generatepassword-in-aspnetcore-ne
        /// </summary>
        private string GeneratePassword(int length, int numberOfNonAlphanumericCharacters)
        {
            char[] Punctuations = "!@#$%^&*()_-+=[{]};:>|./?".ToCharArray();

            if (length < 1 || length > 128)
            {
                throw new ArgumentException(nameof(length));
            }

            if (numberOfNonAlphanumericCharacters > length || numberOfNonAlphanumericCharacters < 0)
            {
                throw new ArgumentException(nameof(numberOfNonAlphanumericCharacters));
            }

            using (var randomNumberGenerator = RandomNumberGenerator.Create())
            {
                var byteBuffer = new byte[length];
                randomNumberGenerator.GetBytes(byteBuffer);

                var count = 0;
                var characterBuffer = new char[length];

                for (var iter = 0; iter < length; iter++)
                {
                    var i = byteBuffer[iter] % 87;

                    if (i < 10)
                    {
                        characterBuffer[iter] = (char)('0' + i);
                    }
                    else if (i < 36)
                    {
                        characterBuffer[iter] = (char)('A' + i - 10);
                    }
                    else if (i < 62)
                    {
                        characterBuffer[iter] = (char)('a' + i - 36);
                    }
                    else
                    {
                        characterBuffer[iter] = Punctuations[i - 62];
                        count++;
                    }
                }

                if (count >= numberOfNonAlphanumericCharacters)
                {
                    return new string(characterBuffer);
                }

                int j;
                var random = new Random();

                for (j = 0; j < numberOfNonAlphanumericCharacters - count; j++)
                {
                    int k;
                    do
                    {
                        k = random.Next(0, length);
                    }
                    while (!char.IsLetterOrDigit(characterBuffer[k]));

                    characterBuffer[k] = Punctuations[random.Next(0, Punctuations.Length)];
                }

                return new string(characterBuffer);
            }
        }

        public async Task<TenantUserCheckResponse> CheckAllUserPresentAndActiveAsync(Guid templateID)
        {
            var useGraphToCreatePersonaFlag = bool.Parse(configurationManager.GetValuefromAppsettings("UseGraphToCreatePersona"));

            var dimensions = new Dictionary<IDimension, string>();
            string correlationId = $"Correlation Id: {demoHubRequestContext?.CorrelationId}.";
            string domainName = demoHubRequestContext.UserDetails.Upn.GetDomainName();
            var personaListIdForCurrentTenant = unitOfWork.DemoTemplatesPersonasRepository.Get(x => x.TemplateId == templateID);
            var templatePersonaLicenseMapping = unitOfWork.DemoTemplatePersonaLicenseMappingRepository.Get(x => x.TemplateId == templateID);
            var allPersonas = unitOfWork.DemoPersonasRepository.Get();
            var personaListForCurrentTenant = allPersonas?.Where(x => personaListIdForCurrentTenant.Any(y => y.PersonaId == x.PersonaId));

            TenantUserCheckResponse tenantUserCheckResponse = new TenantUserCheckResponse();

            // FIX 2: Null-safe empty check. The original `?.Count() == 0` evaluates to `null == 0`
            // (false) when the list is null, allowing a null reference to flow through and crash.
            if (personaListForCurrentTenant == null || !personaListForCurrentTenant.Any())
            {
                tenantUserCheckResponse.TenantUserCheckPassed = true;
                return tenantUserCheckResponse;
            }

            var licenseMappingExtended = templatePersonaLicenseMapping.Select(parent => new DemoTemplatePersonaLicenseMappingExtended()
            {
                PersonaId = parent.PersonaId,
                IsActive = parent.IsActive,
                LicenseSkuId = parent.LicenseSkuId,
                TemplateId = parent.TemplateId,
                personaUPN = personaListForCurrentTenant?.Where(x => x.PersonaId == parent.PersonaId)?.FirstOrDefault()?.PersonaUPN,
                personaFullUPN = personaListForCurrentTenant?.Where(x => x.PersonaId == parent.PersonaId)?.FirstOrDefault()?.PersonaUPN + domainName
            }).ToList();

            IEnumerable<TenantUserAccountStatus> tenantAccountStatus = null;
            try
            {
                tenantAccountStatus = await GetTenantUserAccountStatusAsync(personaListForCurrentTenant);
            }
            catch (Exception ex)
            {
                string errorCode = ex?.GetErrorCode();
                if (string.IsNullOrWhiteSpace(errorCode))
                {
                    errorCode = "NotSpecifiedGraphErrorCode";
                }
                LogAndSetMetrics(
                    dimensions,
                    Convert.ToString(HttpResponseStatusConstants.InternalServerError500),
                    nameof(GetTenantUserAccountStatusAsync),
                    $"{correlationId} {nameof(GetTenantUserAccountStatusAsync)}. Exception occured while making graph call",
                    Metrics.GraphAPIFailure,
                    LogLevel.Error,
                    errorCode,
                    ex);

                tenantUserCheckResponse.TenantUserCheckPassed = false;
                tenantUserCheckResponse.TenantUserCheckErrorMessage = TryAgainMessage;
                return tenantUserCheckResponse;
            }

            var adminUserDetailsGraphCallResult = await msGraphClient.GetAccountsDetails<Dictionary<string, object>>("'" + demoHubRequestContext?.UserDetails.Upn + "'");
            var AdminUserDetails = adminUserDetailsGraphCallResult?.GetValueOrDefault("value")?.ToString()?.DeserializeToObject<List<TenantUserAccountDeatilsGraphResponse>>();
            var usageLocation = AdminUserDetails?[0]?.UsageLocation ?? "US";

            // FIX 3: Use StringBuilder for UsersListMessage so both the "not-created" portion and
            // the "newly-created" portion are accumulated instead of the second assignment overwriting
            // the first with `=`.
            StringBuilder usersListMessageBuilder = new StringBuilder();
            var nonExistedUsers = tenantAccountStatus.Where(x => x.IsExists == false).ToList();

            if (nonExistedUsers.Count > 0)
            {
                if (useGraphToCreatePersonaFlag)
                {
                    foreach (var absentUser in nonExistedUsers)
                    {
                        var userDetails = unitOfWork.DemoPersonasRepository.Get(x => x.PersonaId == absentUser.PersonaID)?.FirstOrDefault();

                        string payload = JsonConvert.SerializeObject(new
                        {
                            accountEnabled = true,
                            displayName = userDetails.DisplayName,
                            jobTitle = userDetails.Title,
                            givenName = userDetails.GivenName,
                            surname = userDetails.Surname,
                            userPrincipalName = userDetails.PersonaUPN + demoHubRequestContext.UserDetails.Upn.GetDomainName(),
                            mailNickname = userDetails.PersonaUPN,
                            passwordProfile = new
                            {
                                password = GeneratePassword(32, 4)
                            },
                            usageLocation = usageLocation
                        });

                        var content = new StringContent(payload, Encoding.UTF8, "application/json");

                        try
                        {
                            var createUserCallResponse = await msGraphClient.CreatePersonaAccountAsync(content);
                            if (createUserCallResponse.IsSuccessStatusCode)
                            {
                                absentUser.IsExists = true;
                                absentUser.IsActive = true;
                            }
                            else
                            {
                                var responseContent = await createUserCallResponse.Content.ReadAsStringAsync();
                                LogAndSetMetrics(
                                    dimensions,
                                    Convert.ToString(HttpResponseStatusConstants.InternalServerError500),
                                    nameof(msGraphClient.CreatePersonaAccountAsync),
                                    $"{correlationId} {nameof(msGraphClient.CreatePersonaAccountAsync)}. Exception occured while creating user {userDetails.PersonaUPN}",
                                    Metrics.GraphAPIFailure,
                                    LogLevel.Error,
                                    ErrorCode.CreatePersonaOperationFailure);
                            }
                        }
                        catch (Exception ex)
                        {
                            string errorCode = ex?.GetErrorCode();
                            if (string.IsNullOrWhiteSpace(errorCode))
                            {
                                errorCode = "NotSpecifiedGraphErrorCode";
                            }
                            LogAndSetMetrics(
                                dimensions,
                                Convert.ToString(HttpResponseStatusConstants.InternalServerError500),
                                nameof(msGraphClient.CreatePersonaAccountAsync),
                                $"{correlationId} {nameof(msGraphClient.CreatePersonaAccountAsync)}. Exception occured while creating user {userDetails.PersonaUPN}",
                                Metrics.GraphAPIFailure,
                                LogLevel.Error,
                                errorCode,
                                ex);
                        }
                    }
                }

                var finalListOfPersonaNonExisted = nonExistedUsers.Where(x => x.IsExists == false).ToList();
                if (finalListOfPersonaNonExisted.Any())
                {
                    StringBuilder errorMessage = new StringBuilder();
                    foreach (var user in finalListOfPersonaNonExisted)
                    {
                        errorMessage.Append(user.UPN).Append(", ");
                    }
                    usersListMessageBuilder.Append(string.Format(UserNotExistInTenant, Regex.Replace(errorMessage.ToString(), ", $", "")));
                }

                var createdUsers = nonExistedUsers.Where(x => x.IsExists == true).ToList();
                if (createdUsers.Any())
                {
                    StringBuilder newPersonaLists = new StringBuilder();
                    foreach (var user in createdUsers)
                    {
                        newPersonaLists.Append(user.UPN).Append(", ");
                    }
                    // FIX 3 continued: Append instead of overwrite so both messages are preserved.
                    usersListMessageBuilder.Append(string.Format(NewUserCreatedInTenant, Regex.Replace(newPersonaLists.ToString(), ", $", "")));
                }
            }

            // FIX 4: Move the inactive-user message construction outside the useGraphToCreatePersonaFlag
            // block so that users who are disabled but whose flag is off are still reported rather than
            // silently allowing the check to pass.
            string inactiveUsersMessage = string.Empty;
            var nonActiveUsers = tenantAccountStatus.Where(x => x.IsActive == false && x.IsExists == true).ToList();
            if (nonActiveUsers.Count > 0)
            {
                if (useGraphToCreatePersonaFlag)
                {
                    foreach (var inactiveUser in nonActiveUsers)
                    {
                        var userDetails = unitOfWork.DemoPersonasRepository.Get(x => x.PersonaId == inactiveUser.PersonaID)?.FirstOrDefault();
                        string payload = JsonConvert.SerializeObject(new { accountEnabled = true });
                        var content = new StringContent(payload, Encoding.UTF8, "application/json");

                        try
                        {
                            var updateUserCallResponse = await msGraphClient.EnablePersonaAccountAsync(content, userDetails.PersonaUPN + demoHubRequestContext.UserDetails.Upn.GetDomainName());
                            if (updateUserCallResponse.IsSuccessStatusCode)
                            {
                                inactiveUser.IsActive = true;
                            }
                            else
                            {
                                var responseContent = await updateUserCallResponse.Content.ReadAsStringAsync();
                                LogAndSetMetrics(
                                    dimensions,
                                    Convert.ToString(HttpResponseStatusConstants.InternalServerError500),
                                    nameof(msGraphClient.EnablePersonaAccountAsync),
                                    $"{correlationId} {nameof(msGraphClient.EnablePersonaAccountAsync)}. Exception occured while enabling {userDetails.PersonaUPN + demoHubRequestContext.UserDetails.Upn.GetDomainName()}",
                                    Metrics.GraphAPIFailure,
                                    LogLevel.Error,
                                    ErrorCode.EnablePersonaOperationFailure);
                            }
                        }
                        catch (Exception ex)
                        {
                            string errorCode = ex?.GetErrorCode();
                            if (string.IsNullOrWhiteSpace(errorCode))
                            {
                                errorCode = "NotSpecifiedGraphErrorCode";
                            }
                            LogAndSetMetrics(
                                dimensions,
                                Convert.ToString(HttpResponseStatusConstants.InternalServerError500),
                                nameof(msGraphClient.EnablePersonaAccountAsync),
                                $"{correlationId} {nameof(msGraphClient.EnablePersonaAccountAsync)}. Exception occured while enabling {userDetails.PersonaUPN + demoHubRequestContext.UserDetails.Upn.GetDomainName()}",
                                Metrics.GraphAPIFailure,
                                LogLevel.Error,
                                errorCode,
                                ex);
                        }
                    }
                }

                // FIX 4: Report remaining disabled users regardless of whether the creation flag is set.
                StringBuilder inactiveUserList = new StringBuilder();
                var finalListOfPersonaNonActive = nonActiveUsers.Where(x => x.IsActive == false && x.IsExists == true).ToList();
                foreach (var user in finalListOfPersonaNonActive)
                {
                    inactiveUserList.Append(user.UPN).Append(", ");
                }

                if (inactiveUserList.Length > 0)
                {
                    inactiveUsersMessage = string.Format(UserDisabledInTenant, Regex.Replace(inactiveUserList.ToString(), ", $", ""));
                }
            }

            string requiredLicenseCheckMessage = string.Empty;

            if (licenseMappingExtended.Any())
            {
                // FIX 5: Actually honour the ValidateRequiredLicenses feature flag. Previously the
                // flag was read but never checked, so license validation always ran.
                bool validateRequiredLicensesFlag = bool.Parse(configurationManager.GetValuefromAppsettings("ValidateRequiredLicenses"));

                if (validateRequiredLicensesFlag)
                {
                    List<string> verifiedLicenseUsers = new();
                    var newCreatedUsers = nonExistedUsers.Where(x => x.IsExists).ToList();

                    foreach (var account in licenseMappingExtended)
                    {
                        try
                        {
                            if (!string.IsNullOrEmpty(account.personaUPN)
                                && !verifiedLicenseUsers.Any(user => user.Equals(account.personaUPN))
                                && !newCreatedUsers.Any(newUser => newUser.UPN.Equals(account.personaFullUPN)))
                            {
                                var licenseDetails = await msGraphClient.GetLicenseDetailsAsync(account.personaFullUPN);

                                if (licenseDetails != null && licenseDetails.Any())
                                {
                                    var requiredLicense = licenseDetails.FirstOrDefault(x => x.SkuId == account.LicenseSkuId);
                                    if (requiredLicense != null)
                                    {
                                        verifiedLicenseUsers.Add(account.personaUPN);
                                    }
                                }
                            }
                        }
                        catch (Exception ex)
                        {
                            string errorCode = ex?.GetErrorCode();
                            if (string.IsNullOrWhiteSpace(errorCode))
                            {
                                errorCode = "NotSpecifiedGraphErrorCode";
                            }
                            LogAndSetMetrics(
                                dimensions,
                                Convert.ToString(HttpResponseStatusConstants.InternalServerError500),
                                nameof(msGraphClient.GetLicenseDetailsAsync),
                                $"{correlationId} {nameof(msGraphClient.GetLicenseDetailsAsync)}. Exception occured while checking required licenses for the user {account.personaFullUPN}",
                                Metrics.GraphAPIFailure,
                                LogLevel.Error,
                                errorCode,
                                ex);
                        }
                    }

                    // FIX 6: Exclude newly-created users from the "missing license" report. They were
                    // intentionally skipped in the loop above (no license yet) but the original Except()
                    // still flagged them because verifiedLicenseUsers only tracked UPN prefixes while
                    // the filter used full UPNs — making the exclusion always miss.
                    var newCreatedUserUpns = newCreatedUsers.Select(u => u.UPN
                        .Replace(domainName, string.Empty, StringComparison.OrdinalIgnoreCase));

                    var usersWithoutRequiredLicense = personaListForCurrentTenant
                        .Select(p => p.PersonaUPN)
                        .Except(verifiedLicenseUsers)
                        .Except(newCreatedUserUpns, StringComparer.OrdinalIgnoreCase);

                    if (usersWithoutRequiredLicense.Any())
                    {
                        string usersWithoutRequiredLicenseUpns = string.Join(", ", usersWithoutRequiredLicense);
                        requiredLicenseCheckMessage = string.Format(UserRequiredLicenseMissing, usersWithoutRequiredLicenseUpns);
                    }
                }
            }

            bool addRequiredLicensesFlag = bool.Parse(configurationManager.GetValuefromAppsettings("AssignRequiredLicenses"));
            StringBuilder licenseAssginationFailureMessage = new StringBuilder();

            if (addRequiredLicensesFlag)
            {
                foreach (var entry in licenseMappingExtended)
                {
                    string payload = JsonConvert.SerializeObject(new
                    {
                        addLicenses = new[] { new { skuId = entry.LicenseSkuId } },
                        removeLicenses = new string[0]
                    });
                    var content = new StringContent(payload, Encoding.UTF8, "application/json");
                    try
                    {
                        var licenseAssignResponse = await msGraphClient.AssignLicenseToPersonaAccountAsync(content, entry.personaFullUPN);
                        if (licenseAssignResponse.IsSuccessStatusCode)
                        {
                            entry.licenseAssignOperationStatus = true;
                        }
                        else
                        {
                            var responseContent = await licenseAssignResponse.Content.ReadAsStringAsync();
                            LogAndSetMetrics(
                                dimensions,
                                Convert.ToString(HttpResponseStatusConstants.InternalServerError500),
                                nameof(msGraphClient.AssignLicenseToPersonaAccountAsync),
                                $"{correlationId} {nameof(msGraphClient.AssignLicenseToPersonaAccountAsync)}. Exception occured while assigning license {entry.LicenseSkuId} for user {entry.personaFullUPN}",
                                Metrics.GraphAPIFailure,
                                LogLevel.Error,
                                ErrorCode.AssignLicenseOperationFailure);
                        }
                    }
                    catch (Exception ex)
                    {
                        string errorCode = ex?.GetErrorCode();
                        if (string.IsNullOrWhiteSpace(errorCode))
                        {
                            errorCode = "NotSpecifiedGraphErrorCode";
                        }
                        LogAndSetMetrics(
                            dimensions,
                            Convert.ToString(HttpResponseStatusConstants.InternalServerError500),
                            nameof(msGraphClient.AssignLicenseToPersonaAccountAsync),
                            $"{correlationId} {nameof(msGraphClient.AssignLicenseToPersonaAccountAsync)}. Exception occured while assigning license {entry.LicenseSkuId} for user {entry.personaFullUPN}",
                            Metrics.GraphAPIFailure,
                            LogLevel.Error,
                            errorCode,
                            ex);
                    }
                }

                var groupedUserList = from mapping in licenseMappingExtended
                                      where mapping.licenseAssignOperationStatus == false
                                      group mapping by mapping.personaFullUPN into groupedList
                                      select groupedList;

                if (groupedUserList.Any())
                {
                    foreach (var group in groupedUserList)
                    {
                        string[] listOfLicense = new string[group.Count()];
                        int i = 0;
                        foreach (var license in group)
                        {
                            listOfLicense[i] = license.LicenseSkuId.ToString();
                            i++;
                        }
                        licenseAssginationFailureMessage.Append(string.Format(LicenseAssignationFailedPerPersonaMessage, group.Key, String.Join(",", listOfLicense)) + ". ");
                    }
                }
            }

            string UsersListMessage = usersListMessageBuilder.ToString();

            if (string.IsNullOrWhiteSpace(UsersListMessage) && string.IsNullOrWhiteSpace(inactiveUsersMessage) && licenseAssginationFailureMessage.Length == 0 && string.IsNullOrWhiteSpace(requiredLicenseCheckMessage))
            {
                tenantUserCheckResponse.TenantUserCheckPassed = true;
                return tenantUserCheckResponse;
            }

            string finalErrorMessageForAccountValidation = string.Empty;

            if (!string.IsNullOrWhiteSpace(UsersListMessage))
            {
                finalErrorMessageForAccountValidation = UsersListMessage;
            }

            if (!string.IsNullOrWhiteSpace(inactiveUsersMessage))
            {
                finalErrorMessageForAccountValidation += inactiveUsersMessage;
            }

            if (licenseAssginationFailureMessage.Length > 0)
            {
                finalErrorMessageForAccountValidation += LicenseAssignationFailedCommonHeading + licenseAssginationFailureMessage.ToString();
            }

            if (!string.IsNullOrWhiteSpace(requiredLicenseCheckMessage))
            {
                finalErrorMessageForAccountValidation += requiredLicenseCheckMessage;
            }

            tenantUserCheckResponse.TenantUserCheckPassed = false;
            tenantUserCheckResponse.TenantUserCheckErrorMessage = finalErrorMessageForAccountValidation;
            return tenantUserCheckResponse;
        }

        private string GetConcatedUserListWithDomain(IEnumerable<DemoPersonasDto> users, string domainName)
        {
            if (users == null || !users.Any())
            {
                return null;
            }

            return string.Join(", ", users.Select(user => $"'{user.PersonaUPN}{domainName}'"));
        }

        private void LogAndSetMetrics(
           Dictionary<IDimension, string> dimensions,
           string apiStatus,
           string apiName,
           string message,
           IMetric metric,
           LogLevel logLevel = LogLevel.Information,
           string? errorCode = null,
           Exception? ex = null)
        {
            if (!string.IsNullOrEmpty(errorCode) && metric.MetricsName == "GraphAPIFailure")
            {
                dimensions.AddDimension(Dimensions.ErrorCode, errorCode);
            }

            dimensions.AddDimension(Dimensions.ApiName, apiName);
            dimensions.AddDimension(Dimensions.ApiStatus, apiStatus);

            metricService.Set(metric, dimensions);

            loggerService.Write(
                   logLevel,
                   message + $"Error Code: {errorCode}  {ex?.InnerException}", dimensions?.ConvertToLogDimensions());
        }
    }
}
