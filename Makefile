# ANA ERP — atalhos de desenvolvimento
.PHONY: subir parar logs compilar eunit dialyzer teste-runtime teste-integracao teste-estudio teste-cluster teste-caos testes limpar

subir:            ## sobe banco + núcleo
	docker compose up -d --build

parar:
	docker compose down

logs:
	docker compose logs -f ana

compilar:
	docker run --rm -v $(PWD):/app -w /app erlang:27 rebar3 compile

eunit:
	docker run --rm -v $(PWD):/app -w /app erlang:27 rebar3 eunit

dialyzer:
	docker run --rm -v $(PWD):/app -v ana-plt:/root/.cache/rebar3 -w /app erlang:27 rebar3 dialyzer

teste-runtime:    ## runtime Python isolado (sem banco)
	python3 -m unittest discover -s tests/runtime -v

teste-integracao: ## requer `make subir`
	python3 -m unittest discover -s tests/integration -v

teste-estudio:    ## DOM real (jsdom) contra o Estúdio; requer `make subir`
	docker run --rm --network host -v $(PWD)/tests/studio:/t -w /t node:22-alpine \
	  sh -c "npm i --silent --no-save jsdom@24 >/dev/null 2>&1 && node smoke.mjs"

teste-cluster:    ## dois nós (sobe e remove o segundo nó)
	tests/cluster/run.sh

teste-caos:       ## dois nós + balanceador: falhas, queda de nó, rolling, banco, restauração
	tests/chaos/run.sh

testes: eunit teste-runtime teste-integracao teste-estudio teste-cluster teste-caos

limpar:           ## apaga containers E dados
	docker compose down -v
