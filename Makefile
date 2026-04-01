REV := $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")
IMAGE := docker.io/jgehrcke/ack:$(REV)

.PHONY: build build-and-push build-and-push-as-latest dashboard profile scale-up scale-down clean

build:
	docker buildx build --progress plain -t $(IMAGE) .

build-and-push:
	docker buildx build --progress plain -t $(IMAGE) --push .

build-and-push-as-latest: build-and-push
	docker buildx build --progress plain -t docker.io/jgehrcke/ack:latest --push .

dashboard:
	-uv run dashboard.py
	stty sane

profile:
	$(eval NODE_IP := $(shell kubectl get pod ack-0 -o jsonpath='{.status.hostIP}'))
	curl -s http://$(NODE_IP):1337/debug/profile-start && echo
	@echo "Profiling for 30s..."
	@sleep 30
	curl -s http://$(NODE_IP):1337/debug/profile-stop && echo
	kubectl cp ack-0:/tmp/profile.pstats /tmp/profile.pstats
	$(eval HOST_IP := $(shell hostname -I | awk '{print $$1}'))
	$(eval SVPORT := $(shell python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()"))
	@echo "http://$(HOST_IP):$(SVPORT)/snakeviz/%2Ftmp%2Fprofile.pstats"
	uv run --with snakeviz snakeviz --server --hostname 0.0.0.0 --port $(SVPORT) /tmp/profile.pstats

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
