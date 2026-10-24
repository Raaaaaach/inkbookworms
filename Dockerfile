FROM ruby:3.3-slim

WORKDIR /app
COPY public ./public
COPY data ./data
COPY server.rb ./

ENV BIND=0.0.0.0
ENV PORT=10000
ENV DATA_DIR=/var/data

RUN mkdir -p /var/data

EXPOSE 10000
CMD ["ruby", "server.rb"]
