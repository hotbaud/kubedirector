# can use Local.mk to override the image var
-include Local.mk

default_image := bluek8s/kubedirector:unstable
image ?= ${default_image}

cluster_resource_name := KubeDirectorCluster
app_resource_name := KubeDirectorApp

project_name := kubedirector

UNAME := $(shell uname)

ifeq ($(UNAME), Linux)
sedseparator =
else
# macOS sed syntax
sedseparator = ''
endif

build_dir = 'tmp/_output'

meow:
	@echo \* Meow

compile:
	make clean
	go build -o tmp/_output/bin ./cmd/kubedirector

build: pkg/apis/kubedirector.bluedata.io/v1alpha1/zz_generated.deepcopy.go | $(build_dir)
	@echo
	@echo \* Creating node prep package...
	tar cfzP tmp/_output/nodeprep.tgz nodeprep
	@echo
	@echo \* Creating KubeDirector deployment image and YAML...
	@test -d vendor || dep ensure -v
	@echo operator-sdk build ${image}
	@operator-sdk build ${image} | grep -v "Create deploy/operator.yaml"
	@docker image prune -f > /dev/null
	@sed -i ${sedseparator} \
        -e '/command:/ {' \
        -e 'n; ' \
        -e 's~.*~          - "/bin/sh"~; G; ' \
        -e 's~$$~          args:~; G; ' \
        -e 's~$$~          - "-c"~; G; ' \
        -e 's~$$~          - "mkfifo /tmp/fifo; (/root/${project_name} \&> /tmp/fifo) \& while true; do cat /tmp/fifo; done"~;' \
        -e '}' deploy/operator.yaml
	@sed -i ${sedseparator} \
        -e '/env:/ {' \
        -e 'G; ' \
        -e 's~$$~            - name: MY_NAMESPACE~; G; ' \
        -e 's~$$~              valueFrom:~; G; ' \
        -e 's~$$~                fieldRef:~; G; ' \
        -e 's~$$~                  fieldPath: metadata.namespace~;' \
        -e '}' deploy/operator.yaml

	@echo "      serviceAccountName: kubedirector" >> deploy/operator.yaml
	@mv deploy/operator.yaml deploy/kubedirector/deployment-localbuilt.yaml
	@echo done
	@echo

pkg/apis/kubedirector.bluedata.io/v1alpha1/zz_generated.deepcopy.go: pkg/apis/kubedirector.bluedata.io/v1alpha1/types.go
	@test -d vendor || dep ensure -v
	operator-sdk generate k8s

push:
	@set -e; \
        if [[ "${image}" == "${default_image}" ]]; then \
            if [[ "${push_default}" == "" ]]; then \
                echo "Use Local.mk to set the image variable, rebuild, then push."; \
                exit 0; \
            fi; \
        fi; \
        echo docker push ${image}; \
        docker push ${image}
	@echo

deploy:
	@set -e; \
        pods_gone=False; \
        kubectl get -o jsonpath='{.items[0].metadata.name}' pods -l name=${project_name} &> /dev/null || pods_gone=True; \
        if [[ "$$pods_gone" != "True" ]]; then \
            echo "KubeDirector pod still exists. Maybe old pod is still terminating?"; \
            exit 1; \
        fi; \
        kubectl_ns=`kubectl config get-contexts | grep '^\*' | awk '{print $$5}'`; \
        if [[ -z "$$kubectl_ns" ]]; then \
            cp -f deploy/kubedirector/rbac-default.yaml deploy/kubedirector/rbac.yaml; \
        else \
            sed "s/namespace: default/namespace: $$kubectl_ns/" deploy/kubedirector/rbac-default.yaml > deploy/kubedirector/rbac.yaml; \
        fi
	@echo
	@echo \* Creating service account...
	kubectl create -f deploy/kubedirector/rbac.yaml
	@echo
	@echo \* Creating custom resource definitions...
	kubectl create -f deploy/kubedirector/crd-cluster.yaml
	kubectl create -f deploy/kubedirector/crd-app.yaml
	@echo
	@echo \* Creating example application types...
	kubectl create -f deploy/example_catalog/
	@echo
	@set -e; \
        if [[ -f deploy/kubedirector/deployment-localbuilt.yaml ]]; then \
        	echo \* Deploying KubeDirector...; \
            kubectl create -f deploy/kubedirector/deployment-localbuilt.yaml; \
        	echo kubectl create -f deploy/kubedirector/deployment-localbuilt.yaml; \
        else \
        	echo \* Deploying PRE-BUILT KubeDirector...; \
        	echo kubectl create -f deploy/kubedirector/deployment-prebuilt.yaml; \
            kubectl create -f deploy/kubedirector/deployment-prebuilt.yaml; \
        fi; \
        podname=`kubectl get -o jsonpath='{.items[0].metadata.name}' pods -l name=${project_name}`; \
        echo; \
        echo KubeDirector pod name is $$podname
	@echo

redeploy:
	@echo
	@echo \* Killing current KubeDirector process \(if any\)...
	@set -e; \
        podname=`kubectl get -o jsonpath='{.items[0].metadata.name}' pods -l name=${project_name}`; \
        kubectl exec $$podname -- killall ${project_name} || true
	@echo
	@echo \* Injecting new node prep package...
	@set -e; \
        podname=`kubectl get -o jsonpath='{.items[0].metadata.name}' pods -l name=${project_name}`; \
        kubectl exec $$podname -- mv -f /root/nodeprep.tgz /root/nodeprep.tgz.bak || true; \
        kubectl cp tmp/_output/nodeprep.tgz $$podname:/root/nodeprep.tgz
	@echo
	@echo \* Injecting and starting new KubeDirector binary...
	@set -e; \
        podname=`kubectl get -o jsonpath='{.items[0].metadata.name}' pods -l name=${project_name}`; \
        kubectl exec $$podname -- /bin/sh -c "echo REDEPLOYING > /tmp/fifo"; \
        kubectl exec $$podname -- mv -f /root/${project_name} /root/${project_name}.bak || true; \
        kubectl cp tmp/_output/bin/${project_name} $$podname:/root/${project_name}; \
        kubectl exec $$podname -- chmod +x /root/${project_name}; \
        kubectl exec -t $$podname -- /bin/sh -c "/root/${project_name} &> /tmp/fifo &"; \
        echo; \
        echo KubeDirector pod name is $$podname
	@echo

undeploy:
	@echo
	@echo \* Deleting any managed virtual clusters...
	-kubectl delete ${cluster_resource_name} --all --now
	@echo
	@echo \* Deleting application types...
	-kubectl delete ${app_resource_name} --all --now
	@echo
	@echo \* Deleting KubeDirector deployment...
	-@if [[ -f deploy/kubedirector/deployment-localbuilt.yaml ]]; then \
        echo kubectl delete -f deploy/kubedirector/deployment-localbuilt.yaml --now; \
        kubectl delete -f deploy/kubedirector/deployment-localbuilt.yaml --now; \
    else \
        echo kubectl delete -f deploy/kubedirector/deployment-prebuilt.yaml --now; \
        kubectl delete -f deploy/kubedirector/deployment-prebuilt.yaml --now; \
    fi
	@echo
	@echo \* Deleting custom resource definitions...
	-kubectl delete -f deploy/kubedirector/crd-app.yaml --now
	-kubectl delete -f deploy/kubedirector/crd-cluster.yaml --now
	@echo
	@echo \* Deleting service account...
	-@if [[ -f deploy/kubedirector/rbac.yaml ]]; then \
        echo kubectl delete -f deploy/kubedirector/rbac.yaml --now; \
        kubectl delete -f deploy/kubedirector/rbac.yaml --now; \
    else \
        echo kubectl delete -f deploy/kubedirector/rbac-default.yaml --now; \
        kubectl delete -f deploy/kubedirector/rbac-default.yaml --now; \
    fi
	@echo
	@echo
	@echo done
	@echo

teardown: undeploy

format:
	go fmt $(shell go list ./... | grep -v /vendor/)

dep:
	dep ensure -v

clean:
	-rm -f deploy/kubedirector/rbac.yaml
	-rm -f deploy/kubedirector/deployment-localbuilt.yaml
	-rm -rf tmp/_output
	make meow

distclean: clean
	-rm -rf vendor

$(build_dir):
	@mkdir -p $@

.PHONY: build push deploy redeploy undeploy teardown format dep clean distclean compile meow
