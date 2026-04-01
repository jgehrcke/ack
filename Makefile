REV := $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")
IMAGE := docker.io/jgehrcke/ack:$(REV)

.PHONY: build build-and-push build-and-push-as-latest dashboard scale-up scale-down clean

build:
	docker buildx build --progress plain -t $(IMAGE) .

build-and-push:
	docker buildx build --progress plain -t $(IMAGE) --push .

build-and-push-as-latest: build-and-push
	docker buildx build --progress plain -t docker.io/jgehrcke/ack:latest --push .

dashboard:
	uv run dashboard.py

scale-up:
	$(eval CURRENT := $(shell kubectl get statefulset ack -o jsonpath='{.spec.replicas}'))
	kubectl scale statefulset ack --replicas=$$(($(CURRENT) + 1))

scale-down:
	$(eval CURRENT := $(shell kubectl get statefulset ack -o jsonpath='{.spec.replicas}'))
	kubectl scale statefulset ack --replicas=$$(($(CURRENT) - 1))

clean:
	kubectl delete statefulset ack --ignore-not-found
	kubectl delete service svc-ack --ignore-not-found
	kubectl delete computedomain ack-compute-domain --ignore-not-found
	kubectl delete resourceclaimtemplate ack-gpu-rct --ignore-not-found
