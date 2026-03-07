ARG BASE_IMAGE

FROM ${BASE_IMAGE}

# Layer the Nexmark SQL application jar on top of the existing Justin image.
COPY --chown=flink:flink nexmark-flink-0.3-SNAPSHOT.jar /opt/flink/lib/nexmark-flink-0.3-SNAPSHOT.jar
