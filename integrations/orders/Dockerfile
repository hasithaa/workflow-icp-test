# The integration as a fat jar. `bal build` runs on the host (it needs the local bala
# repository for the workflow module and the bridge), and scripts/build-artifacts.sh
# stages the jar here.
FROM eclipse-temurin:21-jre

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY artifacts/orders_integration.jar /app/app.jar
COPY Config.toml.tmpl /app/Config.toml.tmpl
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
