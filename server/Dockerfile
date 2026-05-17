FROM node:20-alpine
WORKDIR /app
COPY server.js .
ENV PORT=3001
ENV DATA_DIR=/data
EXPOSE 3001
USER node
CMD ["node", "server.js"]
