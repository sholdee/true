# syntax=docker/dockerfile:1
FROM scratch
ARG BIN=true-103
COPY --chmod=755 out/${BIN} /true
CMD ["/true"]
