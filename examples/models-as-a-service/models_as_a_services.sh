#!/bin/bash

# This script contains prerequisite and post-install steps for the
# Models as a Service example.

prerequisite() {
    echo "--- Running prerequisite steps for Models as a Service ---"

    if ! command -v jq &> /dev/null; then
        echo "Error: jq is not installed. Please install it to continue."
        exit 1
    fi
    if ! command -v yq &> /dev/null;
    then
        echo "Error: yq is not installed. Please install it to continue."
        exit 1
    fi

    # 3scale RWX Storage check
    echo "The 3scale operator requires a storage class with ReadWriteMany (RWX) access mode."
    echo "Red Hat OpenShift Data Foundation (ODF) is the recommended way to provide this."
    read -p "Do you have an RWX-capable storage class available in your cluster? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "An RWX storage class is required. Please install OpenShift Data Foundation (ODF) or another RWX-capable storage solution and then re-run the script."
        exit 1
    fi

    read -p "Please enter the name of the RWX storage class: " rwx_storage_class
    while [ -z "$rwx_storage_class" ]; do
        echo "Storage class name cannot be empty."
        read -p "Please enter the name of the RWX storage class: " rwx_storage_class
    done

    VALUES_YAML_3SCALE_PATH="examples/models-as-a-service/components/3scale/values.yaml"

    # Update wildcard domain
    echo "Discovering cluster wildcard domain..."
    CONSOLE_URL=$(oc whoami --show-console)
    WILDCARD_DOMAIN=$(echo "${CONSOLE_URL}" | sed -n 's/.*\.//p' | cut -d'/' -f1)
    if [ -z "$WILDCARD_DOMAIN" ]; then
        echo "Could not automatically determine wildcard domain. Please update ${VALUES_YAML_3SCALE_PATH} manually."
    else
        WILDCARD_DOMAIN_APPS=$(echo $CONSOLE_URL | sed 's/https.*console-openshift-console\.//' | sed 's/\/$//')
        echo "Found wildcard domain: ${WILDCARD_DOMAIN_APPS}"
        if grep -q "<wildcard-domain>" "$VALUES_YAML_3SCALE_PATH"; then
            echo "Updating 3scale instance with wildcard domain..."
            sed -i.bak "s|<wildcard-domain>|${WILDCARD_DOMAIN_APPS}|" "$VALUES_YAML_3SCALE_PATH"
            rm "${VALUES_YAML_3SCALE_PATH}.bak"
            echo "File ${VALUES_YAML_3SCALE_PATH} updated."
        else
            echo "Wildcard domain seems to be already set in ${VALUES_YAML_3SCALE_PATH}."
        fi
    fi

    if grep -q "<storage-class>" "$VALUES_YAML_3SCALE_PATH"; then
        echo "Updating 3scale instance with storage class: ${rwx_storage_class}"
        sed -i.bak "s|<storage-class>|${rwx_storage_class}|" "$VALUES_YAML_3SCALE_PATH"
        rm "${VALUES_YAML_3SCALE_PATH}.bak"
        echo "File ${VALUES_YAML_3SCALE_PATH} updated."
    else
        echo "Storage class seems to be already set in ${VALUES_YAML_3SCALE_PATH}."
    fi



    echo "--- Prerequisite steps completed. ---"
}

post-install-steps() {
    echo "--- Running post-install steps for Models as a Service ---"

    # Wait for 3scale namespace to be created
    echo "Waiting for the 3scale namespace to be created..."
    until oc get namespace 3scale &> /dev/null; do
        echo "Namespace '3scale' not found. Waiting..."
        sleep 10
    done
    echo "Namespace '3scale' found."
    
    # Wait for 3scale APIManager to be created
    echo "Waiting for 3scale APIManager to be created..."
    until oc get apimanager/apimanager -n 3scale &> /dev/null; do
        echo "APIManager 'apimanager' in namespace '3scale' not found. Waiting..."
        sleep 30
    done
    echo "APIManager 'apimanager' in namespace '3scale' found."

    # Wait for 3scale to be ready
    echo "Waiting for 3scale APIManager to be ready..."
    oc wait --for=condition=Available --timeout=15m apimanager/apimanager -n 3scale

    # Get 3scale admin password
    THREESCALE_ADMIN_PASS=$(oc get secret system-seed -n 3scale -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
    THREESCALE_ADMIN_URL=$(oc get route -l zync.3scale.net/route-to=system-provider -n 3scale -o jsonpath='{.items[0].spec.host}')
    echo "3scale Admin URL: https://${THREESCALE_ADMIN_URL}"
    echo "3scale Admin Password: ${THREESCALE_ADMIN_PASS}"
    echo
    echo "Please follow the 3scale configuration steps from the README to set up backends, products, and application plans."
    echo "Press enter to continue after you have configured 3scale..."
    read

    # Wait for redhat-sso namespace to be created
    echo "Waiting for the redhat-sso namespace to be created..."
    until oc get namespace redhat-sso &> /dev/null; do
        echo "Namespace 'redhat-sso' not found. Waiting..."
        sleep 10
    done
    echo "Namespace 'redhat-sso' found."

    # Wait for REDHAT-SSO Keycloak to be created
    echo "Waiting for statefulset Keycloak to be created..."
    until oc get statefulset/keycloak -n redhat-sso &> /dev/null; do
        echo "statefulset 'keycloak' in namespace 'redhat-sso' not found. Waiting..."
        sleep 30
    done
    echo "statefulset 'keycloak' in namespace 'redhat-sso' found."

    # Get REDHAT-SSO credentials
    echo "Waiting for statefulset 'keycloak' to be ready..."
    oc wait --for=jsonpath='{.status.readyReplicas}'=1 statefulset/keycloak -n redhat-sso --timeout=15m
    
    REDHATSSO_ADMIN_USER=$(oc get secret credential-redhat-sso -n redhat-sso -o jsonpath='{.data.ADMIN_USERNAME}' | base64 -d)
    REDHATSSO_ADMIN_PASS=$(oc get secret credential-redhat-sso -n redhat-sso -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
    REDHATSSO_URL=$(oc get route keycloak -n redhat-sso -o jsonpath='{.spec.host}')
    echo "REDHAT-SSO Admin URL: https://${REDHATSSO_URL}/auth/admin/maas/console/"
    echo "REDHAT-SSO Admin User: ${REDHATSSO_ADMIN_USER}"
    echo "REDHAT-SSO Admin Password: ${REDHATSSO_ADMIN_PASS}"
    echo
    echo "Please follow the REDHAT-SSO configuration steps from the README to create a client for 3scale and configure the identity provider."
    echo "Press enter to continue after you have configured REDHAT-SSO and linked it in 3scale..."
    read

    configure_keycloak_client

    echo "Retrieving 3scale admin access token and host..."
    ACCESS_TOKEN=$(oc get secret system-seed -n 3scale -o jsonpath='{.data.ADMIN_ACCESS_TOKEN}' | base64 -d)
    if [ -z "$ACCESS_TOKEN" ]; then
        echo "Failed to retrieve 3scale access token. Please ensure the 'system-seed' secret exists in the '3scale' namespace and is populated."
        return 1
    fi

    ADMIN_HOST=$(oc get route -n 3scale | grep 'maas-admin' | awk '{print $2}')
    if [ -z "$ADMIN_HOST" ]; then
        echo "Failed to retrieve 3scale admin host. Please ensure the route exists in the '3scale' namespace."
        return 1
    fi
    echo "Found 3scale admin host: ${ADMIN_HOST}"

    read -p "Update 3scale developer portal with the latest content? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        update_developer_portal
    fi

    configure_sso_developer_portal

    # Display test commands
    PROD_API_URL=$(oc get route -n 3scale -o jsonpath='{.items[?(@.spec.to.name=="apicast-production")].spec.host}')
    echo "--- Post-install steps completed! ---"
    echo "You can now test the API. Get an API key from the 3scale developer portal."
    echo
    echo "Example test command:"
    echo "curl -X 'POST' \\"
    echo "    'https://${PROD_API_URL}/v1/completions' \\"
    echo "    -H 'accept: application/json' \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -H 'Authorization: Bearer <YOUR_3SCALE_API_KEY>' \\"
    echo "    -d '{"
    echo "    \"model\": \"<your-model-name>\","
    echo "    \"prompt\": \"San Francisco is a\","
    echo "    \"max_tokens\": 15,"
    echo "    \"temperature\": 0"
    echo "}'"
}

update_developer_portal() {
    echo "--- Updating 3scale Developer Portal ---"

    PORTAL_DIR="examples/models-as-a-service/components/3scale/portal"
    if [ ! -d "$PORTAL_DIR" ]; then
        echo "Portal content directory not found at ${PORTAL_DIR}"
        echo "Please ensure the portal files are located there. You may need to copy them from the original models-aas-demo/3scale/portal directory."
        read -p "Press enter to continue or Ctrl+C to abort."
        return
    fi
    echo "Clean up developer portal content... This may take a moment."
    podman run --userns=keep-id:uid=185 -it --rm -v "$(pwd)/${PORTAL_DIR}":/cms:Z ghcr.io/fwmotion/3scale-cms:latest \
        -k --access-token="${ACCESS_TOKEN}" ${ACCESS_TOKEN} "https://${ADMIN_HOST}" delete --yes-i-really-want-to-delete-the-entire-developer-portal

    echo "Updating developer portal content... This may take a moment."
    podman run --userns=keep-id:uid=185 -it --rm -v "$(pwd)/${PORTAL_DIR}":/cms:Z ghcr.io/fwmotion/3scale-cms:latest \
        -k --access-token="${ACCESS_TOKEN}" ${ACCESS_TOKEN} "https://${ADMIN_HOST}" upload --delete-missing --layout=/l_main_layout.html.liquid

    echo "Developer portal update command executed."
    echo "Note: There is also a 'download' option if you want to make changes manually on the 3scale CMS portal first."
    echo "--- Finished updating 3scale Developer Portal ---"
}

configure_keycloak_client() {
    echo "--- Configuring Keycloak client for 3scale ---"

    echo "Getting Keycloak admin token..."
    KEYCLOAK_TOKEN=$(curl -s -k -X POST "https://${REDHATSSO_URL}/auth/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${REDHATSSO_ADMIN_USER}" \
        -d "password=${REDHATSSO_ADMIN_PASS}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" | jq -r .access_token)

    if [ -z "$KEYCLOAK_TOKEN" ] || [ "$KEYCLOAK_TOKEN" == "null" ]; then
        echo "Failed to get Keycloak admin token. Exiting."
        return 1
    fi
    echo "Successfully got Keycloak admin token."

    REALM="maas"

    echo "Checking if client '3scale' exists in realm '${REALM}'..."
    CLIENT_ID_3SCALE=$(curl -s -k -X GET "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/clients?clientId=3scale" \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" | jq -r '.[0].id')

    if [ -n "$CLIENT_ID_3SCALE" ] && [ "$CLIENT_ID_3SCALE" != "null" ]; then
        echo "Client '3scale' already exists with ID: ${CLIENT_ID_3SCALE}. Skipping creation."
    else
        echo "Client '3scale' does not exist. Creating it..."
        CREATE_CLIENT_PAYLOAD=$(cat <<EOF
{
    "clientId": "3scale",
    "protocol": "openid-connect",
    "publicClient": false,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": false,
    "serviceAccountsEnabled": false,
    "redirectUris": ["*"],
    "bearerOnly": false,
    "consentRequired": false
}
EOF
)
        
        curl -s -k -X POST "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/clients" \
            -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${CREATE_CLIENT_PAYLOAD}"

        CLIENT_ID_3SCALE=$(curl -s -k -X GET "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/clients?clientId=3scale" \
            -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" | jq -r '.[0].id')
        
        if [ -z "$CLIENT_ID_3SCALE" ] || [ "$CLIENT_ID_3SCALE" == "null" ]; then
            echo "Failed to create client '3scale' or retrieve its ID. Exiting."
            return 1
        fi
        echo "Client '3scale' created with ID: ${CLIENT_ID_3SCALE}."
    fi

    CLIENT_SECRET=$(curl -s -k -X GET "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/clients/${CLIENT_ID_3SCALE}/client-secret" \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" | jq -r '.value')
    echo "Client '3scale' secret: ${CLIENT_SECRET}"
    echo "This secret will be used to configure 3scale."

    echo "Adding protocol mappers..."

    # Check for 'email verified' mapper
    MAPPER_EXISTS=$(curl -s -k -X GET "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/clients/${CLIENT_ID_3SCALE}/protocol-mappers/models" \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" | jq -r '.[] | select(.name=="email verified") | .name')

    if [ -n "$MAPPER_EXISTS" ]; then
        echo "'email verified' mapper already exists. Skipping."
    else
        EMAIL_VERIFIED_MAPPER_PAYLOAD=$(cat <<EOF
{
    "name": "email verified",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-property-mapper",
    "consentRequired": false,
    "config": {
        "userinfo.token.claim": "true",
        "user.attribute": "emailVerified",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "claim.name": "email_verified",
        "jsonType.label": "boolean"
    }
}
EOF
)
        curl -s -k -X POST "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/clients/${CLIENT_ID_3SCALE}/protocol-mappers/models" \
            -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${EMAIL_VERIFIED_MAPPER_PAYLOAD}"
        echo "Added 'email verified' mapper."
    fi

    # Check for 'org_type' mapper
    MAPPER_EXISTS=$(curl -s -k -X GET "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/clients/${CLIENT_ID_3SCALE}/protocol-mappers/models" \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" | jq -r '.[] | select(.name=="org_type") | .name')

    if [ -n "$MAPPER_EXISTS" ]; then
        echo "'org_type' mapper already exists. Skipping."
    else
        ORG_TYPE_MAPPER_PAYLOAD=$(cat <<EOF
{
    "name": "org_type",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-attribute-mapper",
    "consentRequired": false,
    "config": {
        "user.attribute": "email",
        "claim.name": "org_name",
        "jsonType.label": "String",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true",
        "aggregate.attributes": "false"
    }
}
EOF
)
        curl -s -k -X POST "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/clients/${CLIENT_ID_3SCALE}/protocol-mappers/models" \
            -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${ORG_TYPE_MAPPER_PAYLOAD}"
        echo "Added 'org_type' mapper."
    fi

    echo "--- Creating developer user ---"
    USER_ID=$(curl -s -k -X GET "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/users?username=developer&exact=true" \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" | jq -r '.[0].id')

    if [ -n "$USER_ID" ] && [ "$USER_ID" != "null" ]; then
        echo "User 'developer' already exists. Skipping creation."
    else
        echo "User 'developer' does not exist. Creating..."
        CREATE_USER_PAYLOAD=$(cat <<EOF
{
    "username": "developer",
    "enabled": true,
    "firstName": "John",
    "lastName": "Doe",
    "email": "user@example.com",
    "emailVerified": true
}
EOF
)
        curl -s -k -X POST "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/users" \
            -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${CREATE_USER_PAYLOAD}"

        USER_ID=$(curl -s -k -X GET "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/users?username=developer&exact=true" \
            -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" | jq -r '.[0].id')
        
        if [ -z "$USER_ID" ] || [ "$USER_ID" == "null" ]; then
            echo "Failed to create user 'developer' or retrieve its ID."
            return 1
        fi
        echo "User 'developer' created with ID: ${USER_ID}."

        DEVELOPER_PASSWORD=$(uuidgen)
        SET_PASSWORD_PAYLOAD=$(cat <<EOF
{
    "type": "password",
    "value": "${DEVELOPER_PASSWORD}",
    "temporary": false
}
EOF
)
        curl -s -k -X PUT "https://${REDHATSSO_URL}/auth/admin/realms/${REALM}/users/${USER_ID}/reset-password" \
            -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${SET_PASSWORD_PAYLOAD}"
        
        echo "Password for 'developer' user has been set."
        echo "Username: developer"
        echo "Password: ${DEVELOPER_PASSWORD}"
    fi

    echo "--- Keycloak client configuration completed. ---"
}

configure_sso_developer_portal() {
    echo "--- Configuring 3scale Developer Portal SSO ---"

    local RESPONSE_FILE
    RESPONSE_FILE=$(mktemp)
    trap 'rm -f -- "$RESPONSE_FILE"' RETURN

    local HTTP_CODE
    HTTP_CODE=$(curl -s -k -w "%{http_code}" -o "${RESPONSE_FILE}" "https://${ADMIN_HOST}/admin/api/authentication_providers.xml?access_token=${ACCESS_TOKEN}")

    if [[ "$HTTP_CODE" -ge 400 ]]; then
        echo "Error: Failed to get Authentication Providers. Received HTTP status ${HTTP_CODE}."
        echo "Response from server:"
        cat "${RESPONSE_FILE}"
        return 1
    fi

    local SSO_INTEGRATION_EXISTS
    SSO_INTEGRATION_EXISTS=$(cat "${RESPONSE_FILE}" | yq -p xml -o json | jq -r '[.authentication_providers.authentication_provider?] | flatten | .[] | select(.kind? == "keycloak") | .id')

    if [ -n "$SSO_INTEGRATION_EXISTS" ]; then
        echo "RH-SSO integration already exists. Skipping creation."
    else
        if [ -z "$CLIENT_SECRET" ]; then
            echo "Error: CLIENT_SECRET is not set. Cannot create SSO integration."
            return 1
        fi
        echo "Creating RH-SSO integration..."
        HTTP_CODE=$(curl -s -k -w "%{http_code}" -o "${RESPONSE_FILE}" \
            -X POST "https://${ADMIN_HOST}/admin/api/authentication_providers.xml?access_token=${ACCESS_TOKEN}" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "kind=keycloak" \
            -d "name=Red Hat Single Sign-On" \
            -d "client_id=3scale" \
            -d "client_secret=${CLIENT_SECRET}" \
            -d "site=https://${REDHATSSO_URL}/auth/realms/maas" \
            -d "published=true")
        
        if [[ "$HTTP_CODE" -ge 400 ]]; then
            echo "Error: Failed to create RH-SSO integration. Received HTTP status ${HTTP_CODE}."
            echo "Response from server:"
            cat "${RESPONSE_FILE}"
            return 1
        fi
        echo "RH-SSO integration created."
    fi

    local AUTH_PROVIDER_ID
    AUTH_PROVIDER_ID=$(curl -s -k -X GET "https://${ADMIN_HOST}/admin/api/authentication_providers.xml?access_token=${ACCESS_TOKEN}" | yq -p xml -o json | jq -r '[.authentication_providers.authentication_provider?] | flatten | .[] | select(.kind? == "keycloak") | .id')
    
    if [ -z "$AUTH_PROVIDER_ID" ]; then
        echo "Failed to retrieve Authentication Provider ID. Cannot update 'Always approve accounts'."
        return 1
    fi

    echo "Updating RH-SSO integration to always approve accounts..."
    HTTP_CODE=$(curl -s -k -w "%{http_code}" -o "${RESPONSE_FILE}" \
        -X PUT "https://${ADMIN_HOST}/admin/api/authentication_providers/${AUTH_PROVIDER_ID}.xml?access_token=${ACCESS_TOKEN}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "automatically_approve_accounts=true")

    if [[ "$HTTP_CODE" -ge 400 ]]; then
        echo "Error: Failed to update RH-SSO integration. Received HTTP status ${HTTP_CODE}."
        echo "Response from server:"
        cat "${RESPONSE_FILE}"
        return 1
    fi
    echo "RH-SSO integration updated."

    echo "--- 3scale Developer Portal SSO configuration completed. ---"
} 