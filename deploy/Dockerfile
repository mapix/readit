# Build context: parent dir containing landing/ and deploy/
# Docker Hub is unreachable from novarocks; use locally cached mirror of nginx:1.25-alpine
ARG BASE=harbor.novarock.dev:8080/mirrors/nginx:1.25-alpine
FROM ${BASE}
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY landing/ /usr/share/nginx/html/
