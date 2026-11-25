.PHONY: test lint up

test:
	cd server && go test ./...
	cd app && flutter test

lint:
	cd server && go vet ./...
	cd app && flutter analyze

up:
	docker compose -f deploy/docker-compose.yml up -d
