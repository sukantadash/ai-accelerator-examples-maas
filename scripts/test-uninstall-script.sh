oc delete applicationset models-as-a-service -n openshift-gitops

oc get csv -n 3scale | grep 3scale | awk '{print $1}' | xargs -I {} oc delete csv {} -n 3scale
oc delete apimanager apimanager -n 3scale
oc delete application.argoproj.io 3scale -n openshift-gitops
oc delete namespace 3scale



oc get csv -n redhat-sso | grep sso | awk '{print $1}' | xargs -I {} oc delete csv {} -n redhat-sso
oc get KeycloakRealm -n redhat-sso | awk '{print $1}' | xargs -I {} oc delete KeycloakRealm {} -n redhat-sso
oc get keycloak -n redhat-sso | awk '{print $1}' | xargs -I {} oc delete keycloak {} -n redhat-sso
oc delete application.argoproj.io redhat-sso -n openshift-gitops
oc delete namespace redhat-sso


oc get applicationset models-as-a-service -n openshift-gitops
oc get application.argoproj.io 3scale -n openshift-gitops
oc get application.argoproj.io redhat-sso -n openshift-gitops

oc get namespace 3scale
oc get namespace redhat-sso


ocs-storagecluster-cephfs