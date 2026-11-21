# Política de segurança

O ANA guarda dados financeiros, fiscais e pessoais de empresas. Levamos relatos de vulnerabilidade a sério e
agradecemos a quem os faz com responsabilidade.

## Como relatar
- **Não abra issue pública** nem pull request com detalhes da falha.
- Use o relato privado do GitHub: aba **Security → Report a vulnerability** deste repositório.
- Inclua: versão ou commit, o que é afetado, como reproduzir, o impacto que você vê e, se tiver, a sugestão de
  correção. Não inclua dados reais de terceiros.

## O que esperar
- Confirmação do recebimento em até **3 dias úteis**.
- Avaliação inicial (gravidade e versões afetadas) em até **10 dias úteis**.
- Correção das falhas graves ou críticas o quanto antes; para as demais, na próxima versão. Combinamos com você a
  data da divulgação, normalmente até **90 dias** após o relato ou quando a correção sair, o que vier primeiro.
- Crédito no aviso de segurança, se você quiser.

## Versões cobertas
Recebem correção de segurança: a versão mais recente da linha `master` e a anterior a ela. Instalações com
contrato de suporte recebem os avisos antes da divulgação.

## Escopo
- Dentro: o núcleo, o runtime, os programas do produto, o Estúdio, a instalação (`deploy/`) e as APIs.
- Fora: programas escritos por clientes, configurações inseguras feitas pelo administrador da instalação,
  ataques que exigem acesso físico ou credenciais de administrador já comprometidas, e negação de serviço por
  volume.

## Boa-fé
Pesquisa feita de boa-fé, dentro desta política, sem acessar ou alterar dados de terceiros e sem interromper
serviços, não será objeto de ação do titular do ANA ERP.
