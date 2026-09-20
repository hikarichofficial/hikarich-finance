-- P3 (Step 15 §7): decimal-safe money, currency and rounding primitives.
-- Authority: Step 04 §14 (rounding, currency, precision), Step 13 §25 (money/decimal convention).
-- PostgreSQL numeric is the authoritative engine; nothing here uses floating point. Rounding lives in
-- exactly one place so no caller sprinkles its own rounding logic.

-- NaN and +/-Infinity are legal numeric values in PostgreSQL but never legal money, rates or weights.
create function app_private.is_finite(p_value numeric) returns boolean
language sql immutable as $$
  select p_value is not null and p_value <> 'NaN'::numeric
     and p_value <> 'Infinity'::numeric and p_value <> '-Infinity'::numeric
$$;

-- Number of minor-unit decimals of a currency (from the ISO 4217 reference table).
create function app_private.currency_scale(p_currency public.currency_code) returns integer
language sql stable as $$
  select c.minor_unit::integer from public.currencies c where c.code = p_currency
$$;

-- Rounds to p_scale decimals. Modes:
--   half_up   ties go away from zero (default for documents and tax lines, Step 04 §14)
--   half_even ties go to the even neighbour (banker's rounding, for aggregate/derived figures)
--   down      truncates toward zero
--   up        rounds away from zero whenever anything is dropped
create function app_private.round_amount(p_amount numeric, p_scale integer, p_mode text default 'half_up')
returns numeric
language plpgsql immutable as $$
declare
  v_factor numeric;
  v_scaled numeric;
  v_floor numeric;
  v_frac numeric;
  v_result numeric;
begin
  if p_amount is null then
    return null;
  end if;
  if not app_private.is_finite(p_amount) then
    raise exception 'INVALID: amount must be a finite number' using errcode = 'invalid_parameter_value';
  end if;
  if p_scale is null or p_scale < 0 or p_scale > 10 then
    raise exception 'INVALID: rounding scale must be between 0 and 10' using errcode = 'invalid_parameter_value';
  end if;
  v_factor := power(10::numeric, p_scale);
  v_scaled := p_amount * v_factor;

  case p_mode
    when 'half_up' then
      v_result := sign(v_scaled) * floor(abs(v_scaled) + 0.5);
    when 'half_even' then
      v_floor := floor(v_scaled);
      v_frac := v_scaled - v_floor;
      if v_frac > 0.5 then
        v_result := v_floor + 1;
      elsif v_frac < 0.5 then
        v_result := v_floor;
      elsif mod(v_floor, 2) = 0 then
        v_result := v_floor;
      else
        v_result := v_floor + 1;
      end if;
    when 'down' then
      v_result := trunc(v_scaled);
    when 'up' then
      v_result := sign(v_scaled) * ceil(abs(v_scaled));
    else
      raise exception 'INVALID: unknown rounding mode %', p_mode using errcode = 'invalid_parameter_value';
  end case;

  return v_result / v_factor;
end
$$;

-- Converts an original-currency amount to the currency of `p_currency` (normally the Entity base currency)
-- and rounds once, with the currency's own minor unit. The rate is preserved by the caller (Step 04 §14).
create function app_private.convert_amount(
  p_amount numeric, p_rate numeric, p_currency public.currency_code, p_mode text default 'half_up')
returns numeric
language plpgsql stable as $$
begin
  if not app_private.is_finite(p_rate) or p_rate <= 0 then
    raise exception 'INVALID: exchange rate must be a positive finite number' using errcode = 'invalid_parameter_value';
  end if;
  return app_private.round_amount(p_amount * p_rate, app_private.currency_scale(p_currency), p_mode);
end
$$;

-- Splits p_total across weights with the largest-remainder method so the parts always add up to the total
-- exactly (no penny is created or lost). Ties on the remainder go to the earliest position.
create function app_private.allocate_amount(p_total numeric, p_weights numeric[], p_scale integer)
returns numeric[]
language plpgsql immutable as $$
declare
  v_factor numeric;
  v_units numeric;
  v_sign numeric := case when p_total < 0 then -1 else 1 end;
  v_sum numeric := 0;
  v_n integer := coalesce(cardinality(p_weights), 0);
  v_base numeric[] := array[]::numeric[];
  v_frac numeric[] := array[]::numeric[];
  v_assigned numeric := 0;
  v_left numeric;
  v_i integer;
  v_best integer;
  v_raw numeric;
begin
  if v_n = 0 then
    raise exception 'INVALID: at least one weight is required' using errcode = 'invalid_parameter_value';
  end if;
  if not app_private.is_finite(p_total) or p_scale is null or p_scale < 0 or p_scale > 10 then
    raise exception 'INVALID: total must be finite and the scale between 0 and 10' using errcode = 'invalid_parameter_value';
  end if;
  v_factor := power(10::numeric, p_scale);
  v_units := abs(p_total) * v_factor;
  if v_units <> trunc(v_units) then
    raise exception 'INVALID: total has more decimals than the allocation scale' using errcode = 'invalid_parameter_value';
  end if;
  for v_i in 1..v_n loop
    if not app_private.is_finite(p_weights[v_i]) or p_weights[v_i] < 0 then
      raise exception 'INVALID: weights must be non-negative' using errcode = 'invalid_parameter_value';
    end if;
    v_sum := v_sum + p_weights[v_i];
  end loop;
  if v_sum <= 0 then
    raise exception 'INVALID: weights must not all be zero' using errcode = 'invalid_parameter_value';
  end if;

  for v_i in 1..v_n loop
    v_raw := v_units * p_weights[v_i] / v_sum;
    v_base := v_base || floor(v_raw);
    v_frac := v_frac || (v_raw - floor(v_raw));
    v_assigned := v_assigned + floor(v_raw);
  end loop;

  v_left := v_units - v_assigned;
  while v_left > 0 loop
    v_best := null;
    for v_i in 1..v_n loop
      if p_weights[v_i] > 0 and (v_best is null or v_frac[v_i] > v_frac[v_best]) then
        v_best := v_i;
      end if;
    end loop;
    v_base[v_best] := v_base[v_best] + 1;
    v_frac[v_best] := -1;
    v_left := v_left - 1;
  end loop;

  for v_i in 1..v_n loop
    v_base[v_i] := v_sign * v_base[v_i] / v_factor;
  end loop;
  return v_base;
end
$$;

revoke all on function app_private.is_finite(numeric) from public;
revoke all on function app_private.currency_scale(public.currency_code) from public;
revoke all on function app_private.round_amount(numeric, integer, text) from public;
revoke all on function app_private.convert_amount(numeric, numeric, public.currency_code, text) from public;
revoke all on function app_private.allocate_amount(numeric, numeric[], integer) from public;
