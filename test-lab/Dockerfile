# Linux-testomgeving voor de WSL2-sandbox.
#
# Dit is stap A: bubblewrap-handhaving en de lock-keys toetsen zonder Windows. Wat hier
# groen wordt geldt ook in WSL2, want die gebruikt dezelfde primitieven (bubblewrap + socat).
# Wat hier NIET te toetsen valt: wslInheritsWindowsSettings, /mnt/c en het cmd.exe-gat -
# dat is stap B, de Windows-VM.
FROM ubuntu:24.04

# bubblewrap en socat zijn wat de sandbox nodig heeft; ripgrep zit in de Claude-binary.
# node en python3 hebben de fixture en de preflights nodig.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bubblewrap socat ripgrep ca-certificates curl python3 git sudo \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code @anthropic-ai/sandbox-runtime

# Een gewone gebruiker, want de sandbox draait niet als root en een developer is ook geen root.
RUN useradd -m -s /bin/bash dev && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
USER dev
WORKDIR /home/dev
RUN mkdir -p /home/dev/repos

CMD ["/bin/bash"]
