#!/bin/bash

echo "Cleaning up Failed pods"
kubectl delete pods --field-selector status.phase=Failed -A

echo "Cleaning up Succeeded pods"
kubectl delete pods --field-selector status.phase=Succeeded -A

