#!/usr/bin/env bash
set -e

INSTANCE_TYPE=${INSTANCE_TYPE:-m6a.xlarge}

ocp_aws_cluster(){
  TARGET_NS=kube-system
  OBJ=secret/aws-creds
  echo "Checking if ${OBJ} exists in ${TARGET_NS} namespace"
  oc -n "${TARGET_NS}" get "${OBJ}" -o name > /dev/null 2>&1 || return 1
  echo "AWS cluster detected"
}

ocp_aws_clone_machineset(){
  MACHINE_SET=$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep worker | head -n1)

  # Safety: only create if infra machineset does not already exist
  if oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep -q "infra"; then
    echo "Exists: infra machineset — skipping creation"
  else
    echo "Creating: infra machineset from ${MACHINE_SET}"
    oc -n openshift-machine-api \
      get "${MACHINE_SET}" -o yaml | \
        sed '/machine/ s/-worker/-infra/g
          /name/ s/-worker/-infra/g
          s/instanceType.*/instanceType: '"${INSTANCE_TYPE}"'/
          s/replicas.*/replicas: 1/' | \
      oc apply -f -
  fi
}

ocp_aws_patch_machineset(){
  MACHINE_SET_TYPE=$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep infra | head -n1)
  PATCH_FILE="$(dirname "$0")/machineset-patch.yaml"

  if [ -f "${PATCH_FILE}" ]; then
    echo "Patching ${MACHINE_SET_TYPE} with labels and taints"
    oc -n openshift-machine-api \
      patch "${MACHINE_SET_TYPE}" \
      --type=merge --patch-file "${PATCH_FILE}"
  else
    echo "Patch file ${PATCH_FILE} not found"
    exit 1
  fi

  echo "Setting instance type to ${INSTANCE_TYPE}"
  oc -n openshift-machine-api \
    patch "${MACHINE_SET_TYPE}" \
    --type=merge --patch '{"spec":{"template":{"spec":{"providerSpec":{"value":{"instanceType":"'"${INSTANCE_TYPE}"'"}}}}}}'
}

ocp_create_infra_autoscale(){
  # Only create autoscaler for the infra machineset — not all machinesets
  MACHINE_SET=$(oc -n openshift-machine-api get machinesets.machine.openshift.io -o name | grep infra | head -n1 | sed 's@.*/@@')

  echo "Creating MachineAutoscaler for ${MACHINE_SET}"
cat << YAML | oc apply -f -
apiVersion: "autoscaling.openshift.io/v1beta1"
kind: "MachineAutoscaler"
metadata:
  name: "${MACHINE_SET}"
  namespace: "openshift-machine-api"
spec:
  minReplicas: 1
  maxReplicas: 2
  scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: "${MACHINE_SET}"
YAML
}

ocp_aws_cluster || exit 0
ocp_aws_clone_machineset
ocp_aws_patch_machineset
ocp_create_infra_autoscale

echo "Infra MachineSet created and autoscaler configured."
