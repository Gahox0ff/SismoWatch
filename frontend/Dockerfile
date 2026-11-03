FROM nginx:alpine
ARG API_URL=""
COPY index.html /usr/share/nginx/html/index.html
RUN echo "window.API_URL='${API_URL}';" > /usr/share/nginx/html/config.js
EXPOSE 80
