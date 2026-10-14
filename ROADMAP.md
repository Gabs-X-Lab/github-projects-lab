# Roadmap — Agendaí

> Plataforma SaaS de agendamento online para clínicas e consultórios.
>
> **Projeto fictício**, criado para o laboratório de GitHub Projects + GitHub Actions.
>
> Este arquivo é atualizado manualmente via Pull Request. Ao concluir um item, marque `[x]` e abra um PR.

**Legenda**

- `[ ]` pendente · `[x]` concluído
- `🔴` prioridade alta · `🟡` média · `🟢` baixa
- `(P/M/G)` estimativa de tamanho: pequeno, médio, grande
- `@usuario`: responsável
- `🚧` em andamento

---

## Q4 2026 — MVP

### Autenticação

- [x] Login com e-mail e senha 🔴 (M) @Gabs-X
- [x] Cadastro de clínica 🔴 (M)
- [ ] 🚧 Login com Google (OAuth) 🔴 (M) @Gabs-X
- [ ] Recuperação de senha por e-mail 🔴 (P)
- [ ] Autenticação em dois fatores (2FA) 🟡 (G)
  - [ ] Envio de código por SMS
  - [ ] Aplicativo autenticador (TOTP)
- [ ] Expiração de sessão por inatividade 🟢 (P)

### Agenda

- [x] Cadastro de profissionais 🔴 (P)
- [ ] 🚧 Visualização de agenda semanal 🔴 (G)
- [ ] Bloqueio de horários (férias, feriados) 🟡 (M)
- [ ] Agendamento recorrente 🟡 (G)
- [ ] Lista de espera para horários cancelados 🟢 (M)

### Pacientes

- [ ] Cadastro de pacientes 🔴 (M)
- [ ] Histórico de consultas do paciente 🟡 (M)
- [ ] Importação de pacientes via CSV 🟢 (M)

---

## Q1 2027 — Engajamento

### Notificações

- [ ] Lembrete de consulta por e-mail 🔴 (M)
- [ ] Lembrete de consulta por WhatsApp 🔴 (G)
- [ ] Confirmação de presença pelo paciente 🟡 (M)
- [ ] Preferências de notificação por paciente 🟢 (P)

### Dashboard

- [ ] Dashboard inicial com consultas do dia 🔴 (M)
- [ ] Relatório de taxa de faltas (no-show) 🟡 (M)
- [ ] Relatório de faturamento mensal 🟡 (G)
- [ ] Exportação de relatórios (PDF / Excel) 🟢 (M)

---

## Q2 2027 — Financeiro

### Pagamentos

- [ ] Integração com gateway de pagamento 🔴 (G)
- [ ] Cobrança antecipada no agendamento 🟡 (M)
- [ ] Emissão de recibo 🟡 (P)
- [ ] Planos de assinatura para clínicas 🟡 (G)

---

## Sugestões (ainda não priorizadas)

- Aplicativo mobile para pacientes
- Integração com Google Calendar
- Teleconsulta por vídeo
- Modo escuro no painel
- Avaliação do atendimento após a consulta

---

## Débitos técnicos

- [ ] Migrar testes de integração para containers 🟡 (M)
- [ ] Configurar monitoramento de erros 🟡 (P)
- [x] Pipeline de CI com lint e testes 🔴 (P)
