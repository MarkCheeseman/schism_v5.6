!   Copyright 2014 College of William and Mary
!
!   Licensed under the Apache License, Version 2.0 (the "License");
!   you may not use this file except in compliance with the License.
!   You may obtain a copy of the License at
!
!     http://www.apache.org/licenses/LICENSE-2.0
!
!   Unless required by applicable law or agreed to in writing, software
!   distributed under the License is distributed on an "AS IS" BASIS,
!   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
!   See the License for the specific language governing permissions and
!   limitations under the License.

! Generate [TEM,SAL]_nu.nc from gridded data (nc file)
! The section on nc read needs to be modified as appropriate- search for
! 'start11' and 'end11'
! Beware the order of vertical levels in the nc file!!!
! Assume elev=0 in interpolation of 3D variables
! The code will do all it can to extrapolate: below bottom/above surface.
! If a pt in hgrid.ll is outside the background nc grid, const. values will be filled. 
!
! ifort -mcmodel=medium -CB -O2 -o gen_nudge_from_hycom gen_nudge_from_hycom.f90 ../UtilLib/compute_zcor.f90 -I$NETCDF/include -I$NETCDF_FORTRAN/include -L$NETCDF_FORTRAN/lib -L$NETCDF/lib -lnetcdf -lnetcdff

!   Input: 
!     (1) hgrid.gr3;
!     (2) hgrid.ll;
!     (3) vgrid.in (SCHISM R3000 and up);
!     (4) include.gr3: if depth=0, skip the interpolation to speed up;
!     (5) gen_nudge_from_nc.in: 
!                     1st line: T,S values for pts outside bg grid in nc (make sure nudging zone is inside bg grid in nc)
!                     2nd line: time step in .nc in sec; output stride
!                     3rd line: # of nc files
!     (6) HYCOM files: TS_[1,2,..nfiles].nc (includes lon/lat; beware scaling etc)
!   Output: [TEM,SAL]_nu.nc 
!   Debug outputs: fort.11 (fatal errors); fort.*

      program gen_hot
      use netcdf

!      implicit none

!      integer, parameter :: debug=1
!      integer, parameter :: mnp=600000
!      integer, parameter :: mne=1200000
!      integer, parameter :: mnv=60
      integer, parameter :: nbyte=4
      real, parameter :: small1=1.e-2 !used to check area ratios
  
!     netcdf related variables
      integer :: sid, tid, ncids(100),one_dim ! Netcdf file IDs
      integer :: latvid, lonvid, zmvid, hvid ! positional variables
      integer :: xdid, xvid ! longitude index
      integer :: ydid, yvid ! latitude index
      integer :: ldid, lvid ! vertical level, 1 is top
      integer :: svid, tvid ! salt & temp variable IDs
      integer :: uvid, vvid ! vel variable IDs
      integer :: evid ! SSH variable IDs
      integer :: var1d_dims(1),var4d_dims(4)
      integer, dimension(nf90_max_var_dims) :: dids
             
!     Local variables for data
      real (kind = 4), allocatable :: xind(:), yind(:), lind(:) 
!     Lat, lon, bathymetry
      real (kind = 4), allocatable :: lat(:,:), lon(:,:), hnc(:)
!     Vertical postion, salinity, and temperature
      real (kind = 4), allocatable :: zm(:,:,:),salt(:,:,:),temp(:,:,:), &
     &uvel(:,:,:),vvel(:,:,:),ssh(:,:)
      integer, allocatable :: kbp(:,:),ihope(:,:)
!     File names for netcdf files
      character(len=1024) :: ncfile1,ncfile2
!     Command line arguments
      character(len=1024) :: s, yr, md
      character(len=4) :: iyear_char
      character(len=1) :: char1,char2
      character(len=20) :: char3,char4
      character(len=2) :: hr_char(4)
!     external function for number of command line arguments
      integer :: iargc

      integer :: status ! netcdf local status variable
      integer :: ier ! allocate error return.
      integer :: ixlen, iylen, ilen ! sampled lengths in each coordinate direction
      integer :: ixlen1, iylen1,ixlen2, iylen2 !reduced indices for CORIE grid to speed up interpolation
!      integer :: elnode(4,mne)
!      dimension xl(mnp),yl(mnp),dp(mnp),i34(mne),include2(mnp)
!      dimension tempout(mnp,mnv), saltout(mnp,mnv)
!      dimension ztot(0:mnv),sigma(mnv),ixy(mnp,3),arco(3,mnp)
      real, allocatable :: xl(:),yl(:),dp(:),tempout(:,:),saltout(:,:),ztot(:),sigma(:),arco(:,:)
      integer, allocatable :: i34(:),elnode(:,:),include2(:),ixy(:,:)
      dimension wild(100),wild2(100,2)
      dimension nx(4,4,3),month_day(12)
      dimension ndays_mon(12)
      allocatable :: z(:,:),sigma_lcl(:,:),kbp2(:),iparen_of_dry(:,:)
      real*8 :: aa1(1)

!     First statement
      ndays_mon=(/31,28,31,30,31,30,31,31,30,31,30,31/)  !# of days in each month for non-leap yr
!      hr_char=(/'03','09','15','21'/) !each day has 4 starting hours in ROMS

      open(10,file='gen_nudge_from_nc.in',status='old')
      read(10,*) tem_outside,sal_outside !T,S values for pts outside bg grid in nc or include.gr3
      read(10,*) dtout,nt_out !time step in .nc [sec], output stride
      !read(10,*) istart_year,istart_mon,istart_day 
      read(10,*) nndays !# of nc files
      close(10)

!     Read in hgrid and vgrid
      open(16,file='hgrid.ll',status='old')
      open(15,file='include.gr3',status='old')
      open(14,file='hgrid.gr3',status='old') !only need depth info and connectivity
      open(19,file='vgrid.in',status='old')
      open(11,file='fort.11',status='replace')
      read(14,*)
      read(14,*)ne,np
      allocate(xl(np),yl(np),dp(np),i34(ne),elnode(4,ne),include2(np),ixy(np,3),arco(3,np))
      read(16,*); read(16,*)
      read(15,*); read(15,*)
      do i=1,np
        read(14,*)j,xtmp,ytmp,dp(i)
        read(16,*)j,xl(i),yl(i) !,dp(i)
        read(15,*)j,xtmp,ytmp,tmp
        include2(i)=nint(tmp)
      enddo !i
      do i=1,ne
        read(14,*)j,i34(i),(elnode(l,i),l=1,i34(i))
      enddo !i
!     Open bnds
!      read(14,*) nope
!      read(14,*) neta
!      ntot=0
!      if(nope>mnope) stop 'Increase mnope (2)'
!      do k=1,nope
!        read(14,*) nond(k)
!        if(nond(k)>mnond) stop 'Increase mnond'
!        do i=1,nond(k)
!          read(14,*) iond(k,i)
!        enddo
!      enddo

      close(14)
      close(15)
      close(16)

!     V-grid
      read(19,*)ivcor
      read(19,*)nvrt
      rewind(19)
      allocate(ztot(nvrt),sigma(nvrt),sigma_lcl(nvrt,np),z(np,nvrt),kbp2(np),tempout(np,nvrt),saltout(np,nvrt))
      call get_vgrid('vgrid.in',np,nvrt,ivcor,kz,h_s,h_c,theta_b,theta_f,ztot,sigma,sigma_lcl,kbp2)

!     Compute z-coord.
      do i=1,np
        if(ivcor==2) then
          call zcor_SZ(max(0.11,dp(i)),0.,0.1,h_s,h_c,theta_b,theta_f,kz,nvrt,ztot,sigma,z(i,:),idry,kbp2(i))
        else if(ivcor==1) then !impose min h
          z(i,kbp2(i):nvrt)=max(0.11,dp(i))*sigma_lcl(kbp2(i):nvrt,i)
        else
          write(11,*)'Unknown ivcor:',ivcor
          stop
        endif

        !Extend below bottom for interpolation later
        z(i,1:kbp2(i)-1)=z(i,kbp2(i))
      enddo !i

!     open(54,file='TEM_nu.in',form='unformatted',status='replace')
!     open(55,file='SAL_nu.in',form='unformatted',status='replace')
      iret=nf90_create('TEM_nu.nc',OR(NF90_CLOBBER,NF90_NETCDF4),ncid_T)
      iret=nf90_def_dim(ncid_T,'node',np,node_dim)
      iret=nf90_def_dim(ncid_T,'nLevels',nvrt,nv_dim)
      iret=nf90_def_dim(ncid_T,'one',1,one_dim)
      iret=nf90_def_dim(ncid_T,'time', NF90_UNLIMITED,itime_dim)

      var1d_dims(1)=itime_dim
      iret=nf90_def_var(ncid_T,'time',NF90_DOUBLE,var1d_dims,itime_id_T)
      var4d_dims(1)=one_dim; var4d_dims(2)=nv_dim; 
      var4d_dims(3)=node_dim; var4d_dims(4)=itime_dim
      iret=nf90_def_var(ncid_T,'tracer_concentration',NF90_FLOAT,var4d_dims,ivar_T)
      iret=nf90_enddef(ncid_T)

      iret=nf90_create('SAL_nu.nc',OR(NF90_CLOBBER,NF90_NETCDF4),ncid_S)
      iret=nf90_def_dim(ncid_S,'node',np,node_dim)
      iret=nf90_def_dim(ncid_S,'nLevels',nvrt,nv_dim)
      iret=nf90_def_dim(ncid_S,'one',1,one_dim)
      iret=nf90_def_dim(ncid_S,'time', NF90_UNLIMITED,itime_dim)

      iret=nf90_def_var(ncid_S,'time',NF90_DOUBLE,var1d_dims,itime_id_S)
      iret=nf90_def_var(ncid_S,'tracer_concentration',NF90_FLOAT,var4d_dims,ivar_S)
      iret=nf90_enddef(ncid_S)

!start11
!     Define limits for variables for sanity checks
      tempmin=-15 
      tempmax=50
      saltmin=0
      saltmax=45

!     Assume S,T have same dimensions (and time step) and grids do not change over time
      timeout=-dtout !sec
      irecout=0
      irecout2=0 !final time record # in the output
!      iyr_now=istart_year
!      imon_now=istart_mon
!      iday_now=istart_day-1

      do ifile=1,nndays 
!--------------------------------------------------------------------
      write(char3,'(i20)')ifile
      char3=adjustl(char3); len_char3=len_trim(char3)

!     Open nc file 
      ncfile1='TS_'//char3(1:len_char3)//'.nc'
      print*, 'doing ',trim(ncfile1)
      status = nf90_open(trim(ncfile1),nf90_nowrite, sid)
      call check(status)

!     Get dimnesions from first file, assumed same for all variables
      if(ifile==1) then
        status = nf90_inq_varid(sid, "SALINITY", svid)
        status = nf90_inq_varid(sid, "TEMPERATURE", tvid)
        write(20,*)'Done reading variable ID'

!       WARNING: indices reversed from ncdump!
        status = nf90_Inquire_Variable(sid, svid, dimids = dids)
        status = nf90_Inquire_Dimension(sid, dids(1), len = ixlen)
        status = nf90_Inquire_Dimension(sid, dids(2), len = iylen)
        status = nf90_Inquire_Dimension(sid, dids(3), len = ilen)
        status = nf90_Inquire_Dimension(sid, dids(4), len = ntime)
        print*, 'ixlen,iylen,ilen,ntime= ',ixlen,iylen,ilen,ntime

!       allocate arrays
        allocate(xind(ixlen),stat=ier)
        allocate(yind(iylen),stat=ier)
        allocate(lind(ilen),stat=ier)
        allocate(lat(ixlen,iylen))
        allocate(lon(ixlen,iylen))
        allocate(zm(ixlen, iylen, ilen))
        allocate(hnc(ilen))
        allocate(kbp(ixlen,iylen))
        allocate(ihope(ixlen,iylen))
        allocate(salt(ixlen,iylen,ilen),stat=ier)
        allocate(temp(ixlen,iylen,ilen),stat=ier)
!        allocate(salt0(ixlen,iylen,ilen),stat=ier)
!        allocate(temp0(ixlen,iylen,ilen),stat=ier)
  
!       get static info (lat/lon grids etc) 
        status = nf90_inq_varid(sid, "depth", hvid)
        status = nf90_get_var(sid, hvid, hnc)
        status = nf90_inq_varid(sid, "lon", xvid)
        status = nf90_get_var(sid, xvid, xind)
        status = nf90_inq_varid(sid, "lat", yvid)
        status = nf90_get_var(sid, yvid, yind)

!       processing static info
        do i=1,ixlen
          lon(i,:)=xind(i)
        enddo !i
        do j=1,iylen
          lat(:,j)=yind(j)
        enddo !j
!        lon=lon-360 !convert to our long.

!       Grid bounds for searching for parents  later
!       Won't work across dateline
        xlmin=minval(lon); xlmax=maxval(lon)
        ylmin=minval(lat); ylmax=maxval(lat)

!       Compute z-coord. (assuming eta=0)
!       WARNING: In zm(), 1 is bottom; ilen is surface (SCHISM convention)
        do i=1,ixlen
          do j=1,iylen
            do k=1,ilen
              zm(i,j,k)=-hnc(1+ilen-k)
            enddo !k
          enddo !j
        enddo !i

!       Arrays no longer used after this: hnc,lind
        deallocate(hnc,lind)
      endif !ifile==1 

!     Vertical convention follows SCHISM from now on; i.e., 1 is at bottom
      if(ifile==1) then
        ilo=1 !align time origin
      else
        ilo=1 
      endif !ifile

      do it2=ilo,ntime !time records in each nc file
        irecout=irecout+1
        timeout=timeout+dtout !sec
        write(20,*)'Time out (days)=',timeout/86400

        !Make sure it2=ilo is output (some init. work below)
        if(mod(irecout-1,nt_out)/=0) cycle
        irecout2=irecout2+1

!       Read T,S
!       WARNING! Make sure the order of vertical indices is 1 at bottom, ilen at surface; revert if necessary!
        call cpu_time(tt0)
        status = nf90_get_var(sid,svid,salt(:,:,ilen:1:-1),start=(/1,1,1,it2/),count=(/ixlen,iylen,ilen,1/))
        status = nf90_get_var(sid,tvid,temp(:,:,ilen:1:-1),start=(/1,1,1,it2/),count=(/ixlen,iylen,ilen,1/))

        !Scaling etc
        salt=salt*1.e-3+20
        temp=temp*1.e-3+20
        !Define junk value for sid; the test is abs(salt-rjunk)<1.e-4
        rjunk=-3.e4*1.e-3+20

!       done read nc this step
        call cpu_time(tt1)
        write(20,*)'reading nc this step took (sec):',tt1-tt0
        call flush(20)

!       Do some prep for 1st step only
        if(ifile==1.and.it2==ilo) then
!         Assume these won't change over time iteration!!
!         Find bottom index and extend
          ndrypt=0 !# of dry nodes in nc
          do i=1,ixlen
            do j=1,iylen
              if(abs(salt(i,j,ilen)-rjunk)<1.e-4) then
                kbp(i,j)=-1 !dry
                ndrypt=ndrypt+1
              else !wet
                !Extend near bottom
                klev0=-1 !flag
                do k=1,ilen
                  if(abs(salt(i,j,k)-rjunk)>=1.e-4) then
                    klev0=k; exit
                  endif
                enddo !k
                if(klev0<=0) then
                  write(11,*)'Impossible (1):',i,j,salt(i,j,ilen)
                  stop
                endif !klev0
                salt(i,j,1:klev0-1)=salt(i,j,klev0)
                temp(i,j,1:klev0-1)=temp(i,j,klev0)
                kbp(i,j)=klev0 !>0; <=ilen; may change over time (but /=-1?)

                !Check
                do k=1,ilen
                  if(salt(i,j,k)<saltmin.or.salt(i,j,k)>saltmax.or. &
                    &temp(i,j,k)<tempmin.or.temp(i,j,k)>tempmax) then
                    write(11,*)'Fatal: no valid values:',it2,i,j,k,salt(i,j,k),temp(i,j,k) 
                    stop
                  endif
                enddo !k
              endif !salt
            enddo !j
          enddo !i  
!          print*, 'ndrypt=',ndrypt

!         Compute S,T etc@ invalid pts based on nearest neighbor
!         Search around neighborhood of a pt
          allocate(iparen_of_dry(2,max(1,ndrypt)))
          call cpu_time(tt0)
        
          icount=0
          do i=1,ixlen
            do j=1,iylen
              if(kbp(i,j)==-1) then !invalid pts  
                icount=icount+1
                if(icount>ndrypt) stop 'overflow'
                !Compute max possible tier # for neighborhood
                mmax=max(i-1,ixlen-i,j-1,iylen-j)

                m=0 !tier #
                loop6: do
                  m=m+1
                  do ii=max(-m,1-i),min(m,ixlen-i)
                    i3=max(1,min(ixlen,i+ii))
                    do jj=max(-m,1-j),min(m,iylen-j)
                      j3=max(1,min(iylen,j+jj))
                      if(kbp(i3,j3)>0) then !found
                        i1=i3; j1=j3
                        exit loop6   
                      endif
                    enddo !jj
                  enddo !ii

                  if(m==mmax) then
                    write(11,*)'Max. exhausted:',i,j,mmax
                    write(11,*)'kbp'
                    do ii=1,ixlen
                      do jj=1,iylen
                        write(11,*)ii,jj,kbp(ii,jj)
                      enddo !jj
                    enddo !ii
                    stop
                  endif
                end do loop6

                salt(i,j,1:ilen)=salt(i1,j1,1:ilen)
                temp(i,j,1:ilen)=temp(i1,j1,1:ilen)

                !Save for other steps
                iparen_of_dry(1,icount)=i1
                iparen_of_dry(2,icount)=j1

                !Check 
                do k=1,ilen
                  if(salt(i,j,k)<saltmin.or.salt(i,j,k)>saltmax.or. &
                    &temp(i,j,k)<tempmin.or.temp(i,j,k)>tempmax) then
                    write(11,*)'Fatal: no valid values after searching:',it2,i,j,k,salt(i,j,k),temp(i,j,k) 
                    stop
                  endif
                enddo !k

              endif !kbp(i,j)==-1
            enddo !j=iylen1,iylen2
          enddo !i=ixlen1,ixlen2
          call cpu_time(tt1)
          if(ndrypt/=icount) stop 'mismatch(7)'
          write(20,*)'extending took (sec):',tt1-tt0,ndrypt,icount
          call flush(20)

          !Save T/S for abnormal cases later
!          salt0=salt
!          temp0=temp

          call cpu_time(tt0)
!         Test outputs
          icount=0
          do i=1,ixlen
            do j=1,iylen
              icount=icount+1
              write(98,*)icount,lon(i,j),lat(i,j),salt(i,j,1) !,i,j
              write(99,*)icount,lon(i,j),lat(i,j),temp(i,j,ilen)
              write(100,*)icount,lon(i,j),lat(i,j),temp(i,j,1)
            enddo !j
          enddo !i
          print*, 'done outputting test outputs for nc'
     
!         Find parent elements for hgrid.ll
          ixy=0
          loop4: do i=1,np
            !won't work across dateline
            if(xl(i)<xlmin.or.xl(i)>xlmax.or.yl(i)<ylmin.or.yl(i)>ylmax) cycle loop4
            if(include2(i)==0) cycle loop4

            do ix=1,ixlen-1 
              do iy=1,iylen-1 
                x1=lon(ix,iy); x2=lon(ix+1,iy); x3=lon(ix+1,iy+1); x4=lon(ix,iy+1)
                y1=lat(ix,iy); y2=lat(ix+1,iy); y3=lat(ix+1,iy+1); y4=lat(ix,iy+1)
                a1=abs(signa(xl(i),x1,x2,yl(i),y1,y2))
                a2=abs(signa(xl(i),x2,x3,yl(i),y2,y3))
                a3=abs(signa(xl(i),x3,x4,yl(i),y3,y4))
                a4=abs(signa(xl(i),x4,x1,yl(i),y4,y1))
                b1=abs(signa(x1,x2,x3,y1,y2,y3))
                b2=abs(signa(x1,x3,x4,y1,y3,y4))
                rat=abs(a1+a2+a3+a4-b1-b2)/(b1+b2)
                if(rat<small1) then
                  ixy(i,1)=ix; ixy(i,2)=iy
!                 Find a triangle
                  in=0 !flag
                  do l=1,2 !split quad
                    ap=abs(signa(xl(i),x1,x3,yl(i),y1,y3))
                    if(l==1) then !nodes 1,2,3
                      bb=abs(signa(x1,x2,x3,y1,y2,y3))
                      wild(l)=abs(a1+a2+ap-bb)/bb
                      if(wild(l)<small1*5) then
                        in=1
                        arco(1,i)=max(0.,min(1.,a2/bb))
                        arco(2,i)=max(0.,min(1.,ap/bb))
                        exit
                      endif
                    else !nodes 1,3,4
                      bb=abs(signa(x1,x3,x4,y1,y3,y4))
                      wild(l)=abs(a3+a4+ap-bb)/bb
                      if(wild(l)<small1*5) then
                        in=2
                        arco(1,i)=max(0.,min(1.,a3/bb))
                        arco(2,i)=max(0.,min(1.,a4/bb))
                        exit
                      endif
                    endif
                  enddo !l=1,2
                  if(in==0) then
                    write(11,*)'Cannot find a triangle:',(wild(l),l=1,2)
                    stop
                  endif
                  ixy(i,3)=in
                  arco(3,i)=max(0.,min(1.,1-arco(1,i)-arco(2,i)))
                  cycle loop4
                endif !rat<small1
              enddo !iy=iylen1,iylen2-1
            enddo !ix=ixlen1,ixlen2-1
          end do loop4 !i=1,np

          call cpu_time(tt1)
          write(20,*)'computing weights took:',tt1-tt0
          call flush(20)

        else !skip to extend directly
          do i=1,ixlen
            do j=1,iylen
              if(kbp(i,j)>0) then !valid
                !Extend bottom - kbp changes over time
                klev0=-1 !flag
                do k=1,ilen
                  if(abs(salt(i,j,k)-rjunk)>=1.e-4) then !salt(i,j,k)<rjunk) then
                    klev0=k; exit
                  endif
                enddo !k
                if(klev0<=0) then
                  write(11,*)'Impossible (4):',i,j,salt(i,j,ilen)
                  stop
                endif !klev0
                salt(i,j,1:klev0-1)=salt(i,j,klev0)
                temp(i,j,1:klev0-1)=temp(i,j,klev0)

                !Check
                do k=1,ilen
                  if(salt(i,j,k)<saltmin.or.salt(i,j,k)>saltmax.or. &
                    &temp(i,j,k)<tempmin.or.temp(i,j,k)>tempmax) then
                    write(11,*)'Warning: no valid values-use last value(3):', &
     &it2,i,j,k,salt(i,j,k),temp(i,j,k),';',salt(i,j,:),temp(i,j,:)
!'                   salt(i,j,k)=salt0(i,j,k)
!                    temp(i,j,k)=temp0(i,j,k)
                    stop
                  endif
                enddo !k
              endif !kbp
            enddo !j
          enddo !i

          icount=0
          do i=1,ixlen
            do j=1,iylen
              if(kbp(i,j)==-1) then !dry pt
                icount=icount+1
                !Use extended parents
                i1=iparen_of_dry(1,icount); j1=iparen_of_dry(2,icount)
                salt(i,j,1:ilen)=salt(i1,j1,1:ilen)
                temp(i,j,1:ilen)=temp(i1,j1,1:ilen)

                !Check
                do k=1,ilen
                  if(salt(i,j,k)<saltmin.or.salt(i,j,k)>saltmax.or. &
                    &temp(i,j,k)<tempmin.or.temp(i,j,k)>tempmax) then
                    write(11,*)'Warning: no valid values-use last value(4):', &
     &it2,i,j,k,salt(i,j,k),temp(i,j,k),i1,j1,';', &
     &salt(i1,j1,:),temp(i1,j1,:)
!'                   salt(i,j,k)=salt0(i,j,k)
!                    temp(i,j,k)=temp0(i,j,k)
                    stop
                  endif
                enddo !k
              endif !kbp
            enddo !j
          enddo !i
          if(icount/=ndrypt) stop 'mimatch (8)'

          !Save for later steps
!          salt0=salt
!          temp0=temp
        endif !ifile==1.and.it2==
    
    
!       Do interpolation
!        print*, 'Time out (days)=',timeout/86400,it2,ilo,ntime
        tempout=tem_outside; saltout=sal_outside !init
        do i=1,np
          if(ixy(i,1)==0.or.ixy(i,2)==0) then
!            tempout(i,:)=tem_outside
!            saltout(i,:)=sal_outside
          else !found parent 
            ix=ixy(i,1); iy=ixy(i,2); in=ixy(i,3)
            !Find vertical level
            do k=1,nvrt
              if(kbp(ix,iy)==-1) then
                lev=ilen-1; vrat=1
              else if(z(i,k)<=zm(ix,iy,kbp(ix,iy))) then
                lev=kbp(ix,iy); vrat=0
              else if(z(i,k)>=zm(ix,iy,ilen)) then !above f.s.
                lev=ilen-1; vrat=1
              else
                lev=-99 !flag
                do kk=1,ilen-1
                  if(z(i,k)>=zm(ix,iy,kk).and.z(i,k)<=zm(ix,iy,kk+1)) then
                    lev=kk
                    vrat=(zm(ix,iy,kk)-z(i,k))/(zm(ix,iy,kk)-zm(ix,iy,kk+1))
                    exit
                  endif
                enddo !kk
                if(lev==-99) then
                  write(11,*)'Cannot find a level:',i,k,z(i,k),(zm(ix,iy,l),l=1,kbp(ix,iy))
                  stop
                endif
              endif
          
!              write(18,*)i,k,ix,iy,lev,vrat,kbp(ix,iy)
              wild2(1,1)=temp(ix,iy,lev)*(1-vrat)+temp(ix,iy,lev+1)*vrat
              wild2(1,2)=salt(ix,iy,lev)*(1-vrat)+salt(ix,iy,lev+1)*vrat
              wild2(2,1)=temp(ix+1,iy,lev)*(1-vrat)+temp(ix+1,iy,lev+1)*vrat
              wild2(2,2)=salt(ix+1,iy,lev)*(1-vrat)+salt(ix+1,iy,lev+1)*vrat
              wild2(3,1)=temp(ix+1,iy+1,lev)*(1-vrat)+temp(ix+1,iy+1,lev+1)*vrat
              wild2(3,2)=salt(ix+1,iy+1,lev)*(1-vrat)+salt(ix+1,iy+1,lev+1)*vrat
              wild2(4,1)=temp(ix,iy+1,lev)*(1-vrat)+temp(ix,iy+1,lev+1)*vrat
              wild2(4,2)=salt(ix,iy+1,lev)*(1-vrat)+salt(ix,iy+1,lev+1)*vrat

!              wild2(5,1)=uvel(ix,iy,lev)*(1-vrat)+uvel(ix,iy,lev+1)*vrat
!              wild2(5,2)=vvel(ix,iy,lev)*(1-vrat)+vvel(ix,iy,lev+1)*vrat
!              wild2(6,1)=uvel(ix+1,iy,lev)*(1-vrat)+uvel(ix+1,iy,lev+1)*vrat
!              wild2(6,2)=vvel(ix+1,iy,lev)*(1-vrat)+vvel(ix+1,iy,lev+1)*vrat
!              wild2(7,1)=uvel(ix+1,iy+1,lev)*(1-vrat)+uvel(ix+1,iy+1,lev+1)*vrat
!              wild2(7,2)=vvel(ix+1,iy+1,lev)*(1-vrat)+vvel(ix+1,iy+1,lev+1)*vrat
!              wild2(8,1)=uvel(ix,iy+1,lev)*(1-vrat)+uvel(ix,iy+1,lev+1)*vrat
!              wild2(8,2)=vvel(ix,iy+1,lev)*(1-vrat)+vvel(ix,iy+1,lev+1)*vrat
              if(in==1) then
                tempout(i,k)=wild2(1,1)*arco(1,i)+wild2(2,1)*arco(2,i)+wild2(3,1)*arco(3,i)
                saltout(i,k)=wild2(1,2)*arco(1,i)+wild2(2,2)*arco(2,i)+wild2(3,2)*arco(3,i)
              else
                tempout(i,k)=wild2(1,1)*arco(1,i)+wild2(3,1)*arco(2,i)+wild2(4,1)*arco(3,i)
                saltout(i,k)=wild2(1,2)*arco(1,i)+wild2(3,2)*arco(2,i)+wild2(4,2)*arco(3,i)
              endif

              !Check
              if(tempout(i,k)<tempmin.or.tempout(i,k)>tempmax.or. &
               &saltout(i,k)<saltmin.or.saltout(i,k)>saltmax) then
                write(11,*)'Interpolated values invalid:',i,k,tempout(i,k),saltout(i,k)
                stop
              endif

!             Enforce lower bound for temp. for eqstate
              tempout(i,k)=max(0.,tempout(i,k))
            enddo !k=1,nvrt
          endif !ixy(i,1)==0.or.
        enddo !i=1,np
    
!       Output (junks outside nudging zone)
        print*, 'outputting _nu.nc at day ',timeout/86400
!        write(54)timeout
!        write(55)timeout
        do i=1,np
!          write(54)tempout(i,1:nvrt)
!          write(55)saltout(i,1:nvrt)

!         For debug
          if(ifile==1.and.it2==ilo) then
            write(101,*)i,xl(i),yl(i),tempout(i,nvrt)
            write(102,*)i,xl(i),yl(i),tempout(i,1)
            write(103,*)i,xl(i),yl(i),saltout(i,nvrt)
          endif !ifile
        enddo !i
        close(101); close(102); close(103)

        aa1(1)=timeout/86400
        iret=nf90_put_var(ncid_T,itime_id_T,aa1,(/irecout2/),(/1/))
        iret=nf90_put_var(ncid_S,itime_id_S,aa1,(/irecout2/),(/1/))
        iret=nf90_put_var(ncid_T,ivar_T,transpose(tempout),(/1,1,1,irecout2/),(/1,nvrt,np,1/))
        iret=nf90_put_var(ncid_S,ivar_S,transpose(saltout),(/1,1,1,irecout2/),(/1,nvrt,np,1/))

      enddo !it2=ilo,ntime

      status = nf90_close(sid)
!end11
      print*, 'done reading nc for file ',ifile
!--------------------------------------------------------------------
      enddo !ifile=1,

      iret=nf90_close(ncid_T)
      iret=nf90_close(ncid_S)
!      deallocate(lat,lon,zm,h,kbp,ihope,xind,yind,lind,salt,temp)

      print*, 'Finished'
!     End of main

!     Subroutines
      contains
!     Internal subroutine - checks error status after each netcdf, 
!     prints out text message each time an error code is returned. 
      subroutine check(status)
      integer, intent ( in) :: status
    
      if(status /= nf90_noerr) then 
        print *, trim(nf90_strerror(status))
        print *, 'failed to open nc files'
        stop
      end if
      end subroutine check  

      end program gen_hot

      function signa(x1,x2,x3,y1,y2,y3)

      signa=((x1-x3)*(y2-y3)-(x2-x3)*(y1-y3))/2

      return
      end

