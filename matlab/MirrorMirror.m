classdef MirrorMirror < handle
    % An acoustic propagation model for single seabed layer and isovelocity
    % medium based on the image method.  The workflow of this class is
    % broken into phases: image finding, image filtering, and rendering.
    % image finding is done with the generate_all_images() method which
    % recursively finds images based on the source-receiver geometry and
    % environment.  image filtering provides a means of changing which
    % eigenrays to include in the final rendered output.  the rendering
    % phase converts the retained images into a transfer function (complex
    % spectral values at each frequency for each receiver).
    %
    % Example usage:
    %
    %
    % clear
    % clc
    %
    % mm = MirrorMirror();                                % instantiate
    %
    % mm.seabed_z = -12;                                  % environment
    % mm.seabed_c = 1550;
    % mm.seabed_rho = 1.2;
    %
    % mm.sources_xyz = [ ...                              % sources
    %     100,  100, 0 ; ...
    %     -30,  100, 0 ; ...
    %     -100, -20, 0 ; ...
    %     10, -200,  0 ];
    %
    % rcv_x = [ 0 11 ];                                   % receivers
    % rcv_x = rcv_x - mean(rcv_x);
    % Nr = length(rcv_x);
    % mm.receivers_xyz = [rcv_x(:), zeros(Nr, 1), ...
    %     repmat(mm.seabed_z, Nr, 1)];
    %
    % mm.bounce_count_thresh = 10;                        % stop cond.
    %
    % %%%% image finding
    %
    % mm.generate_all_images();
    %
    % %%%% image filtering
    %
    % mm.retain_image_indices(...
    %     mm.breadcrumb_to_image_indices('', 'bs', 'bsbs'));
    %
    % %%%% rendering
    %
    % fs = 1e6;                                           % sample freq
    % T_max = 2.5*max(mm.images_dist(:))/mm.water_c;      % time axis ext.
    % freq = Freq.newByTime(fs, T_max, [eps 3000]);       % frequencies
    %
    % G = mm.get_transfer_function(freq.fr);              % xfer fcn.
    % [g, t_g] = freq.synthTime(G(:,1,1), ...             % impulse resp.
    %     false, false, true);
    %
    % figure(1); clf;
    % plot(t_g*mm.water_c, g);                            % plot imp. resp
    % title('impulse response');
    % xlabel('wave travel distance (m)');
    %
    % K = mm.get_clairvoyant_csdm(freq.fr);               % build CSDM
    % S = squeeze(K(1,2,:,1));
    % [s, t_s] = freq.synthTime(S, true, false, true);    % xcorr t/series
    %
    % figure(2); clf;
    % plot(t_s*mm.water_c, s);                            % plot xcorr t/s.
    % xlim(3*diff(rcv_x)*[-1 1]);
    % set(gca, 'xtick', [-1 0 1]*diff(rcv_x));
    % set(gca, 'xgrid', 'on');
    % title('cross correlation time series');
    % xlabel('wave travel distance (m)');
    %
    %
    %
    % Author: John Gebbie
    % Institution: Portland State University
    % Creation Date: 2013 July 18
    
    properties
        
        % GEOMETRY
        sources_xyz                     % Target coordinates (1-by-3)
        receivers_xyz                   % Receiver coordinates (N-by-3)
        
        % OUTPUT
        freq                            % Frequencies
        
        % ENVIRONMENT
        air_z = 0                       % Depth of air (m) (defined as 0)
        air_c = 343.21                  % Sound speed in air (m/s)
        air_rho = 1.2041e-3             % Density of air (g/cm^3)
        water_z = 0                     % Depth of water layer (m)
        water_c = 1500                  % Sound speed in water (m/s)
        water_rho = 1                   % Density of water (g/cm^3)
        water_alpha = 1.001438340469e-4 % Attenuation of water (dB/lambda)
        seabed_z = NaN                  % Depth of seabed layer (m)
        seabed_c = 1550                 % Sound speed in seabed (m/s)
        seabed_rho = 1.8                % Density of seabed (g/cm^3)
        seabed_alpha = 0.2              % Attenuation of seabed (dB/lambda)
        
        % STOPPING CONDITIONS
        attenuation_thresh_dB = 100     % Max loss (rel. to 1st arrival)
        bounce_count_thresh = Inf       % Max number of bounces of ray
        time_lag_thresh = Inf           % Max time lag of multipath ray
        
    end
    
    properties
        
        % character that specify which boundary is being reflected from
        BREADCRUMB_SURFACE = 's'
        BREADCRUMB_BOTTOM = 'b'
        
        % populated by generate_all_images()
        images_xyz                      % I-by-S-by-3
        images_dist                     % I-by-R-by-S
        images_vec                      % I-by-R-by-S-by-3
        images_grz_ang_r                % I-by-R-by-S
        images_rcoeff                   % I-by-R-by-S
        images_breadcrumb               % I-by-1 (cell)
        
    end
    
    methods
        
        function [] = reset(o)
            % reset object state so that generate_all_images() can be
            % called again
            o.images_xyz = [];
            o.images_dist = [];
            o.images_vec = [];
            o.images_grz_ang_r = [];
            o.images_rcoeff = [];
            o.images_breadcrumb = {};
        end
        
        function [K] = get_clairvoyant_csdm(o, freq, image_indices)
            % returns the clairvoyant CSDM (no noise, perfect SNR, no
            % decorrelation between rays)
            %
            % INPUTS
            %
            %   freq - array of frequencies (Hz)
            %
            %   image_indicies - array of indicies corresponding to
            %   discovered images that will be included in CSDM
            %
            % OUTPUT
            %
            %   K - The CSDM for each frequency.  This is a
            %   R-by-R-by-F-by-S matrix in which R is the number of
            %   elements and F is the number of requested frequencies, and
            %   S is the number of sources
            if nargin <= 2
                image_indices = 1:o.get_nimg();
            end
            T = o.get_transfer_function(freq, image_indices);
            K = nan(o.get_nelt(), o.get_nelt(), numel(freq), o.get_nsrc());
            for nf = 1:numel(freq)
                for ns = 1:o.get_nsrc()
                    tf = T(nf, :, ns).';
                    K(:,:,nf,ns) = tf*tf';
                end
            end
        end
        
        function [K] = get_clairvoyant_csdm_with_decoherence(o, freq, ...
                coh_factor_seabed, coh_factor_surf, image_indices)
            % similar to get_clairvoyant_csdm() but allowing specification
            % of decorrelation between eigenrays.  this is an ad hoc
            % technique.
            %
            % INPUTS
            %
            %   coh_factor_seabed - a number between 0 and 1 indicating how
            %   much coherence is retained as rays reflect from the seabed.
            %   this is raised to the power of the number of bounces, so
            %   higher-order eigenrays have exponentially degraded
            %   coherence retention.
            %
            %   coh_factor_surf - same but for the surface.
            if nargin <= 4
                image_indices = 1:o.get_nimg();
            end
            K = zeros(o.get_nelt(), o.get_nelt(), numel(freq));
            for n1 = image_indices
                T1 = o.get_transfer_function(freq, n1);
                Bb1 = sum(o.images_breadcrumb{n1} == o.BREADCRUMB_BOTTOM);
                Bs1 = sum(o.images_breadcrumb{n1} == o.BREADCRUMB_SURFACE);
                for n2 = image_indices
                    T2 = o.get_transfer_function(freq, n2);
                    Bb2 = sum(o.images_breadcrumb{n2} == ...
                        o.BREADCRUMB_BOTTOM);
                    Bs2 = sum(o.images_breadcrumb{n2} == ...
                        o.BREADCRUMB_SURFACE);
                    coh_factor = coh_factor_seabed^(Bb1+Bb2) * ...
                        coh_factor_surf^(Bs1+Bs2);
                    for nf = 1:numel(freq)
                        T1f = T1(nf, :).';
                        T2f = T2(nf, :).';
                        K(:,:,nf) = K(:,:,nf) + coh_factor.*(T1f*T2f');
                    end
                end
            end
        end
        
        function [T] = get_transfer_function(o, freq, image_indices)
            % Transfer function for the current set of images.
            %
            % INPUTS
            %
            %   freq - array of frequencies (Hz).
            %
            %   image_indices - see get_clairvoyant_csdm(), optional
            %
            % OUTPUTS
            %
            %   T - the transfer function computed as a sum of all ray
            %   arrivals based on the superposition principle. an
            %   F-by-R-by-S matrix in which F is the number of frequencies,
            %   R is the number of receivers, and S is the number of
            %   sources. see Freq.synthTime
            if nargin <= 2
                image_indices = 1:o.get_nimg();
            end
            T = zeros(numel(freq), o.get_nelt(), o.get_nsrc());
            minus_ik = (-1i*2*pi./o.water_c)*freq(:);
            minus_ik = repmat(minus_ik, 1, o.get_nelt(), o.get_nsrc());
            for n = image_indices
                R = o.images_rcoeff(n, :, :) ./ o.images_dist(n, :, :);
                R = repmat(R, numel(freq), 1, 1);
                D = repmat(o.images_dist(n, :, :), numel(freq), 1, 1);
                T = T + R.*exp(minus_ik.*D);
            end
        end
        
        function [index] = breadcrumb_to_image_indices(o, varargin)
            % convert breadcrumb strings that identify specific eigenrays
            % to indices in the list of computed images. this allows for
            % convenient identification of specific eigenrays.
            %
            % INPUTS
            %
            %   varargin - a variable list of strings (i.e. '', 'bs') in
            %   which the characters of each string specify the boundary
            %   reflections of an eigenray.
            %
            % OUTPUTS
            %
            %   index - a list of indicies for discovered eigenrays. if a
            %   breadcrumb does not exist in the computed images, it is
            %   silently dropped from the output index list.
            index = nan(size(varargin));
            for m = 1:length(varargin)
                for n = 1:o.get_nimg()
                    if strcmp(o.images_breadcrumb{n}, varargin{m})
                        index(m) = n;
                        break;
                    end
                end
            end
            index(isnan(index)) = [];
        end
        
        function [] = retain_image_indices(o, image_indices)
            % filter the computed images to retain only the ones having
            % specific indices.  this is useful during analysis of the
            % eigenray arrival structure.
            %
            % INPUTS
            %
            %   image_indices - a list of indices to retain. all indices
            %   must exist.
            o.images_xyz = o.images_xyz(image_indices, :, :);
            o.images_dist = o.images_dist(image_indices, :, :);
            o.images_vec = o.images_vec(image_indices, :, :, :);
            o.images_grz_ang_r = o.images_grz_ang_r(image_indices, :, :);
            o.images_rcoeff = o.images_rcoeff(image_indices, :, :);
            o.images_breadcrumb = o.images_breadcrumb(image_indices, 1);
        end
        
        function [] = generate_all_images(o)
            % image generation.  compute the images (eigenrays) based on
            % the environment and source-receiver geometry.  the latter is
            % specified in properties of this object.  when this function
            % completes, get_transfer_function() and get_clairvoyant_csdm()
            % methods can be called.
            
            % init with source
            o.images_xyz(1, :, :) = o.sources_xyz;
            o.images_dist(1, :, :) = o.get_dist(o.sources_xyz);
            o.images_vec(1, :, :, :) = o.get_vec(o.sources_xyz);
            o.images_grz_ang_r(1, :, :) = NaN(o.get_nelt(), o.get_nsrc());
            o.images_rcoeff(1, :, :) = ones(o.get_nelt(), o.get_nsrc());
            o.images_breadcrumb{1, 1, 1} = '';
            
            reflect_surface = any(o.sources_xyz(:,3) ~= o.water_z);
            if reflect_surface
                o.generate_all_images_helper(o.BREADCRUMB_SURFACE);
            end
            
            reflect_seabed = any(o.sources_xyz(:,3) ~= o.seabed_z);
            if reflect_seabed
                o.generate_all_images_helper(o.BREADCRUMB_BOTTOM);
            end
            
        end
        
        function [] = generate_all_images_helper(o, bndry)
            % helper function for generate_all_images(). start recursing by
            % reflecting source over boundary.
            
            % validate stopping conditions
            isnneg = @(x) isfinite(x) && 0 <= x;
            assert( isfinite(o.attenuation_thresh_dB) || ...
                isnneg(o.bounce_count_thresh) || ...
                isnneg(o.time_lag_thresh), ...
                'invalid stopping conditions' );
            
            % prior state
            last_xyz = o.sources_xyz;
            last_bc = '';
            nbnc_s = 0;         % number of surface bounces
            nbnc_b = 0;         % number of bottom bounces
            
            % calculations that can be performed outside loop
            D_direct = o.get_dist(o.sources_xyz);
            spreading_loss_dir_dB = 20*log10(D_direct);
            
            while true
                
                last_nbnc = nbnc_s + nbnc_b;
                if last_nbnc >= o.bounce_count_thresh
                    break;
                end
                
                % breadcrumb
                curr_bc = [last_bc bndry];
                
                % next image coordinates
                switch bndry
                    case o.BREADCRUMB_SURFACE
                        boundary_z = o.water_z;
                        nbnc_s = nbnc_s + 1;
                        bndry = o.BREADCRUMB_BOTTOM;
                    case o.BREADCRUMB_BOTTOM
                        boundary_z = o.seabed_z;
                        nbnc_b = nbnc_b + 1;
                        bndry = o.BREADCRUMB_SURFACE;
                end
                curr_xyz = o.get_image(last_xyz, boundary_z);
                
                % if receiver is AT a boundary, it cannot be the last
                % boundary reflected from. test for this and don't include
                % it in the list of valid images and instead skip to the
                % next boundary
                if all(boundary_z == o.receivers_xyz(:, 3))
                    last_xyz = curr_xyz;
                    last_bc = curr_bc;
                    continue;
                end
                
                % receiver to image vector
                vec = o.get_vec(curr_xyz);
                D_multipath = sqrt(sum(vec.^2, 3));
                
                % check if we've reached the time lag threshold
                if isfinite(o.time_lag_thresh)
                    lag = D_multipath / o.water_c;
                    if all(lag(:) > o.time_lag_thresh)
                        break;
                    end
                end
                
                % grazing angle (same for all boundaries)
                grz_ang_r = abs(atan2(vec(:, :, 3), ...
                    sqrt(sum(vec(:, :, 1:2).^2, 3))));
                
                % cumulative reflection coefficient for current ray
                curr_rc = 1;
                if nbnc_s > 0
                    rc1 = o.get_reflection_coeff_surface(grz_ang_r);
                    curr_rc = curr_rc .* rc1.^nbnc_s;
                end
                if nbnc_b > 0
                    rc1 = o.get_reflection_coeff_seabed(grz_ang_r);
                    curr_rc = curr_rc .* rc1.^nbnc_b;
                end
                
                % check if we've reached the attenuation threshold
                if isfinite(o.attenuation_thresh_dB)
                    spreading_loss_mpath_dB = 20*log10(D_multipath);
                    reflection_loss_dB = -20*log10(abs(curr_rc));
                    loss_rel_dB = spreading_loss_mpath_dB - ...
                        spreading_loss_dir_dB + reflection_loss_dB;
                    if all(loss_rel_dB(:) > o.attenuation_thresh_dB(:))
                        break;
                    end
                end
                
                % save the image info for this loop iteration
                o.images_xyz(end+1, :, :) = curr_xyz;
                o.images_dist(end+1, :, :) = D_multipath;
                o.images_vec(end+1, :, :, :) = vec;
                o.images_grz_ang_r(end+1, :, :) = grz_ang_r;
                o.images_rcoeff(end+1, :, :) = curr_rc;
                o.images_breadcrumb{end+1, 1} = curr_bc;
                
                % setup for next iteration through the loop
                last_xyz = curr_xyz;
                last_bc = curr_bc;
            end
            
        end
        
        function [Ne] = get_nelt(o)
            % return the number of receivers
            Ne = size(o.receivers_xyz, 1);
        end
        
        function [Ne] = get_nsrc(o)
            % return the number of receivers
            Ne = size(o.sources_xyz, 1);
        end
        
        function [Ni] = get_nimg(o)
            % return the number of images
            Ni = size(o.images_xyz, 1);
        end
        
        function [vec_xyz] = get_vec(o, pts_xyz)
            % returns the vector with head at each receiver and tail at the
            % specified input point.
            %
            % INPUTS
            %
            %   pts_xyz - a point in space. an P-by-3 matrix of cartesian
            %   coordinates in which P is the number of points.
            %
            % OUTPUTS
            %
            %   vec_xyz - a R-by-P-by-3 vector of distances (in meters)
            %   between the P points and each R receivers.
            P = size(pts_xyz,1);
            R = o.get_nelt();
            t1 = repmat(permute(o.receivers_xyz,[1 3 2]),1,P,1);
            t2 = repmat(permute(pts_xyz,[3 1 2]),R,1,1);
            vec_xyz = t1 - t2;
        end
        
        function [dist_m] = get_dist(o, pts_xyz)
            % returns the distance between the point and the receivers
            %
            % INPUTS
            %
            %   pts_xyz - see get_vec()
            %
            % OUTPUTS
            %
            %   dist_m - a R-by-P vector of distances (in meters) between
            %   the P points and each R receivers.
            dist_m = sqrt(sum(o.get_vec(pts_xyz).^2, 3));
        end
        
        function [img_xyz] = get_image(o, pts_xyz, boundary_z) %#ok
            % returns the image of pts_xyz after it is reflected over
            % boundary_z.
            %
            % INPUTS
            %
            %   pts_xyz - see get_vec()
            %
            %   boundary_z - the z coordinate of the boundary to reflect
            %   over
            %
            % OTUPUTS
            %
            %   img_xyz - a P-by-3 vector of the image coordinates
            img_xyz = pts_xyz;
            img_xyz(:, 3) = boundary_z - (img_xyz(:, 3) - boundary_z);
        end
        
        function [ang_r] = get_crit_ang(o, bndry_c)
            % returns the critical angle (in radians) for the boundary with
            % sound speed bndry_c
            %
            % INPUTS
            %
            %   bndry_c - sound speed of boundary medium (m/s)
            %
            % OUTPUTS
            %
            %   ang_r - the critical angle (in radians) measured from the
            %   horizontal.
            ang_r = real(acos(o.water_c/bndry_c));
        end
        
        function [R] = get_reflection_coeff_surface(o, grz_ang_rad)
            % returns the reflection coefficient of the surface. this is
            % based on the environmental properties in this object.
            %
            % INPUTS
            %
            %   gr_ang_rad - grazing angle measured from the horizontal
            %
            % OUTPUTS
            %
            %   R - complex reflection coefficient
            R = o.get_reflection_coeff(...
                grz_ang_rad, o.air_c, o.air_rho);
        end
        
        function [R] = get_reflection_coeff_seabed(o, grz_ang_rad)
            % same as get_reflection_coeff_surface(), but for the seabed.
            % assumes a single seabed layer.
            R = o.get_reflection_coeff(...
                grz_ang_rad, o.seabed_c, o.seabed_rho);
        end
        
        function [R] = get_reflection_coeff(o, grz_ang_rad, ...
                c_lyr2, rho_lyr2)
            % Compute the reflection coefficient
            %
            % Based on Equation (2.127) on page 95 in the following
            % reference.
            %
            % F. B. Jensen, W. A. Kuperman, M. B. Porter, and H. Schmidt,
            % Computational Ocean Acoustics.    New York: Springer-Verlag
            % New York, Inc., 2000.
            %
            % INPUTS
            %
            %   grz_ang - grazing angle (radians) in incident medium with
            %   respect to horizontal
            
            c1 = o.water_c;
            c2 = c_lyr2;
            rho1 = o.water_rho;
            rho2 = rho_lyr2;
            
            k1 = 1./c1;
            k2 = 1./c2;
            kr1 = cos(grz_ang_rad).*k1;
            kz1 = sin(grz_ang_rad).*k1;
            kr2 = kr1;
            kz2 = sqrt(k2.^2 - kr2.^2);
            
            t1 = rho2.*kz1;
            t2 = rho1.*kz2;
            R = (t1-t2)./(t1+t2);
        end
        
    end
    
end
