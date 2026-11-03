# resto2 (grupo 9 #47/#55): gravador de firmware do SkyConnect / ZBT-1 / ZBT-2
# (universal-silabs-flasher, o mesmo do HA). Não roda sozinho: o supervisor
# cria um container de uma vez com a porta serial (`/system/radio/*`).
# Imagem local: `docker compose --profile flasher build flasher`.
FROM python:3.12-slim
RUN pip install --no-cache-dir "universal-silabs-flasher>=0.0.25,<0.1"
COPY flash.py /flash.py
ENTRYPOINT ["python", "/flash.py"]
