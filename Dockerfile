FROM alpine:3.20
ARG BUILD_NUMBER=0
ENV BUILD_NUMBER=${BUILD_NUMBER}
CMD ["sh", "-c", "echo Hello from GitHub OIDC build ${BUILD_NUMBER}; sleep 3600"]
