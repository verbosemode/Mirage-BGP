FROM mirage-bgp:latest

RUN rm -rf mrt-format \
&& rm -rf Mirage-BGP

COPY --chown=opam:opam mrt-format /home/opam/mrt-format
COPY --chown=opam:opam Bgp4 /home/opam/Mirage-BGP

RUN cd Mirage-BGP/src/bgpd \
&& eval `opam config env` \
&& mirage clean \
&& mirage configure -t unix --net socket \
&& make depend \
&& make



# FROM mirage-bgp:latest

# RUN rm -rf mrt-format && rm -rf Mirage-BGP

# COPY --chown=opam:opam mrt-format /home/opam/mrt-format
# COPY --chown=opam:opam Bgp4 /home/opam/Mirage-BGP

# RUN cd Mirage-BGP/src/bgpd && eval `opam config env` && mirage configure -t unix --net socket && make depend

# RUN cd Mirage-BGP/src/bgpd && eval `opam config env` && make
