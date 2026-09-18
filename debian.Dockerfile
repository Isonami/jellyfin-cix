# debian systemd image to run container for agent tests
FROM debian:trixie
RUN apt-get update && apt-get install -y systemd
CMD [ "/lib/systemd/systemd" ]
