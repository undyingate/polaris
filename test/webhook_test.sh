#!/bin/bash
set -e

#sed is replacing the polaris version with this commit sha so we are testing exactly this verison.
sed -ri "s|'(quay.io/fairwinds/polaris:).+'|'\1${CIRCLE_SHA1}'|" ./deploy/webhook.yaml
# TODO: remove this after 1.0 is released
sed -i "s/--webhook/webhook/" ./deploy/webhook.yaml

# Testing to ensure that the webhook starts up, allows a correct deployment to pass,
# and prevents a incorrectly formatted deployment. 
function check_webhook_is_ready() {
    # Get the epoch time in one minute from now
    local timeout_epoch

    # Reset another 2 minutes to wait for webhook
    timeout_epoch=$(date -d "+3 minutes" +%s)

	while ! kubectl get csr | grep -E "polaris-webhook.polaris"; do
        check_timeout "${timeout_epoch}"
        echo -n "."
	done
	kubectl certificate approve polaris-webhook.polaris

    # loop until this fails (desired condition is we cannot apply this yaml doc, which means the webhook is working
    echo "Waiting for webhook to be ready"
    while ! kubectl get pods -n polaris | grep -E "webhook.*1/1.*Running"; do
        check_timeout "${timeout_epoch}"
        echo -n "."
    done

    echo "Webhook started!"
}

# Check if timeout is hit and exit if it is
function check_timeout() {
    local timeout_epoch="${1}"
    if [[ "$(date +%s)" -ge "${timeout_epoch}" ]]; then
        echo -e "Timeout hit waiting for readiness: exiting"
        grab_logs
        clean_up
        exit 1
    fi

}

# Clean up all your stuff
function clean_up() {
    # Clean up files you've installed (helps with local testing)
    for filename in test/webhook_cases/*.yaml; do
        # || true to avoid issues when we cannot delete
        kubectl delete -f $filename &>/dev/null ||true
    done
    # Uninstall webhook and webhook config
    kubectl delete validatingwebhookconfigurations polaris-webhook --wait=false &>/dev/null
    kubectl -n polaris delete deploy -l app=polaris --wait=false &>/dev/null
}

function grab_logs() {
    kubectl -n polaris get pods -oyaml -l app=polaris
    kubectl -n polaris describe pods -l app=polaris
	kubectl -n polaris logs -l app=polaris -c webhook-certificate-generator
    kubectl -n polaris logs -l app=polaris
}

# Install a bad deployment
kubectl create ns scale-test
kubectl apply -n scale-test -f ./test/webhook_cases/failing_test.deployment.yaml

# Install the webhook 
kubectl apply -f ./deploy/webhook.yaml &> /dev/null


# wait for the webhook to come online
check_webhook_is_ready
sleep 30

# Webhook started, setting all tests as passed initially.
ALL_TESTS_PASSED=1

# Run tests against correctly configured objects
for filename in test/webhook_cases/passing_test.*.yaml; do
    echo $filename
    if ! kubectl apply -f $filename &> /dev/null; then
        ALL_TESTS_PASSED=0
        echo "Test Failed: Polaris prevented a deployment with no configuration issues." 
        kubectl logs -n polaris $(kubectl get po -oname -n polaris | grep webhook)
    fi
done

# Run tests against incorrectly configured objects
for filename in test/webhook_cases/failing_test.*.yaml; do
    echo $filename
    if kubectl apply -f $filename &> /dev/null; then
        ALL_TESTS_PASSED=0
        echo "Test Failed: Polaris should have prevented this deployment due to configuration issues."
        kubectl logs -n polaris $(kubectl get po -oname -n polaris | grep webhook)
    fi
done

kubectl -n scale-test scale deployment nginx-deployment --replicas=2
sleep 5
kubectl get po -n scale-test
pod_count=$(kubectl get po -n scale-test -oname | wc -l)
if [ $pod_count != 2 ]; then
  ALL_TESTS_PASSED=0
  echo "Existing deployment was unable to scale after webhook installed: found $pod_count pods"
fi

clean_up

#Verify that all the tests passed.
if [ $ALL_TESTS_PASSED -eq 1 ]; then
    echo "Tests Passed."
else
    echo "Tests Failed."
    exit 1
fi
