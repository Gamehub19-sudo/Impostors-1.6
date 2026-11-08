# Impostor & Inocente — sala de espera

1. No Supabase do jogo, abra SQL Editor e execute TODO o arquivo `atualizacao_supabase_parties.sql`. Ele inclui a estrutura e as funções; não é necessário executar arquivos SQL antigos primeiro.
2. Confirme que Anonymous Sign-ins está ativado em Authentication.
3. Substitua o `index.html` no GitHub pelo arquivo deste pacote.
4. Abra o jogo em dois navegadores/dispositivos diferentes: um cria a party e compartilha o código; o outro entra.
5. A sala mostra o anfitrião primeiro e atualiza a lista a cada segundo. Somente o anfitrião pode começar. Há pelo menos um inocente e a quantidade de impostores escolhida nas opções.
6. O sorteio acontece no servidor e cada pessoa vê somente seu próprio papel. Kill, task, report, sabotagem e fantasmas continuam disponíveis.

A correção precisa do SQL no servidor: trocar somente o HTML não cria as funções do banco. Se houver erro, a tela mostra a orientação correspondente. No mesmo navegador, a sessão é compartilhada; use outro dispositivo, perfil ou janela privada para testar como outra pessoa.

Correção de vagas e código: a criação retorna imediatamente o código, o anfitrião e o limite escolhido. As opções são 4, 6, 8, 10 e 12 jogadores (incluindo o anfitrião). O banco bloqueia a entrada acima desse limite. Execute o SQL completo atualizado antes de publicar o HTML.

Correção da entrada de convidados (tabelas antigas):
- Se já executou o SQL completo anterior, execute somente corrigir_entrada_party.sql no Supabase.
- Para uma instalação nova, o atualizacao_supabase_parties.sql já inclui a correção.
- Publique o index.html deste pacote. O servidor devolvia erro de coluna alive ausente ao consultar os jogadores; criar a tabela com IF NOT EXISTS não adicionava essa coluna em instalações antigas.
- O limite escolhido continua valendo, com máximo de 12 pessoas incluindo o anfitrião.
